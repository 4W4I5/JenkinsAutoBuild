#!/usr/bin/env bash
set -eux

export TARGET_PROJECT="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
export TARGET_ARCH="${2:-${TARGET_ARCH:-x86_64}}"

OSS_FUZZ_DIR="${WORKSPACE:-$PWD}/oss-fuzz"
PROJECT_DIR="${OSS_FUZZ_DIR}/projects/${TARGET_PROJECT}"
OUTPUT_DIR="${OSS_FUZZ_DIR}/build/out/${TARGET_PROJECT}/symsan"
SYMSAN_IMAGE="${3:-${SYMSAN_IMAGE:-oss-fuzz-symsan-latest}}"

mkdir -p "${OUTPUT_DIR}"

echo "========================================"
echo "Building SymSan symbolic binary"
echo "Project: ${TARGET_PROJECT}"
echo "Architecture: ${TARGET_ARCH}"
echo "========================================"

# Use the locally-built project image (helper.py tags it as PROJECT:latest, NOT with arch tag)
PROJECT_IMAGE="${TARGET_PROJECT}:latest"

COMPILE_IMAGE="${SYMSAN_IMAGE}-${TARGET_PROJECT}-compile"

DOCKERFILE_DIR="${OSS_FUZZ_DIR}/build/tmp_symsan_dockerfile_${TARGET_PROJECT}"
mkdir -p "${DOCKERFILE_DIR}"

cat > "${DOCKERFILE_DIR}/Dockerfile" <<EOF
FROM ${PROJECT_IMAGE} AS oss_fuzz_project

FROM ubuntu:24.04

COPY --from=oss_fuzz_project /src /src
COPY --from=oss_fuzz_project /out /out

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/lib/llvm-18/bin:/opt/symsan/bin:${PATH}"

# Minimal deps for helper.py and compilation
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-dev python-is-python3 gcc g++ make cmake \
        libc6-dev libstdc++-13-dev zlib1g-dev ca-certificates \
        && rm -rf /var/lib/apt/lists/*

# Bring ko-clang and ko-clang++ from the Symsan image
COPY --from=${SYMSAN_IMAGE} /opt/symsan/bin /opt/symsan/bin
ENV PATH="/opt/symsan/bin:/usr/lib/llvm-18/bin:${PATH}"
EOF

docker build -t "${COMPILE_IMAGE}" -f "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}" || {
    echo "ERROR: Failed to build compiler image for ${TARGET_PROJECT}"
    exit 1
}

# Run compilation inside the compiled image where ko-clang exists.
docker run --rm \
    -v "${OSS_FUZZ_DIR}/infra:/oss-fuzz-infra" \
    -v "${PROJECT_DIR}:/src" \
    -v "${OUTPUT_DIR}:/out" \
    -e FUZZING_ENGINE=afl \
    -e SANITIZER=none \
    -e ARCHITECTURE="${TARGET_ARCH}" \
    -e PROJECT_NAME="${TARGET_PROJECT}" \
    -e HELPER=True \
    -e CC=/opt/symsan/bin/ko-clang \
    -e CXX=/opt/symsan/bin/ko-clang++ \
    -e KO_CC=clang-18 \
    -e KO_CXX=clang++-18 \
    -e KO_USE_FASTGEN=1 \
    -e AFL_LLVM_CMPLOG=0 \
    "${COMPILE_IMAGE}" \
    bash -c '
        cd /src && ls -la build.sh *.fuzz.cpp 2>/dev/null || true

        # Try oss-fuzz helper.py first (it handles project-specific compile logic)
        python3 /oss-fuzz-infra/helper.py build_fuzzers \
            --engine=afl \
            --sanitizer=none \
            --architecture="${TARGET_ARCH}" \
            --clean \
            "${TARGET_PROJECT}" 2>&1 || {
            echo "helper.py failed, trying direct compile with ko-clang"
            ls -la /src/*.fuzz.cpp /src/build.sh 2>/dev/null || true

            # Manual compile attempt for fuzz targets
            for f in /src/*.fuzz.cpp; do
                [ -f "$f" ] && echo "Compiling $f -> /out/$(basename "${f%.cpp}")_symsan" \
                    && /opt/symsan/bin/ko-clang "$f" -o "/out/$(basename "${f%.cpp}")_symsan" 2>&1 || true
            done

            # Try build.sh as fallback
            if [ -f /src/build.sh ]; then
                echo "Trying build.sh with ko-clang in PATH..."
                CC=/opt/symsan/bin/ko-clang CXX=/opt/symsan/bin/ko-clang++ KO_USE_FASTGEN=1 bash /src/build.sh 2>&1 || true
            fi
        }
    '

rm -rf "${DOCKERFILE_DIR}"

# Check if any binaries were produced
SYMSAN_BINARIES=$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -perm -111 ! -name '*.so' ! -name '*.a' 2>/dev/null | sort)

if [ -z "${SYMSAN_BINARIES}" ]; then
    echo "ERROR: No SymSan executable was produced."
    ls -la "${OUTPUT_DIR}/" || true
    exit 1
fi

echo "SymSan symbolic build completed successfully:"
echo "${SYMSAN_BINARIES}"
