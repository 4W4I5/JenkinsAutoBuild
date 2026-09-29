#!/usr/bin/env bash
set -eux

export TARGET_PROJECT="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
export TARGET_ARCH="${2:-${TARGET_ARCH:-x86_64}}"

OSS_FUZZ_DIR="${WORKSPACE:-$PWD}/oss-fuzz"
PROJECT_DIR="${OSS_FUZZ_DIR}/projects/${TARGET_PROJECT}"
OUTPUT_DIR="${OSS_FUZZ_DIR}/build/out/${TARGET_PROJECT}/symsan"

mkdir -p "${OUTPUT_DIR}"

echo "========================================"
echo "Building SymSan symbolic binary"
echo "Project: ${TARGET_PROJECT}"
echo "Architecture: ${TARGET_ARCH}"
echo "========================================"

# Build a compiler image that wraps the OSS-Fuzz project image with ko-clang added
COMPILE_IMAGE="${SYMSAN_IMAGE}-${TARGET_PROJECT}-compile"

DOCKERFILE_DIR="${OSS_FUZZ_DIR}/build/tmp_symsan_dockerfile_${TARGET_PROJECT}"
mkdir -p "${DOCKERFILE_DIR}"

cat > "${DOCKERFILE_DIR}/Dockerfile" <<EOF
FROM gcr.io/oss-fuzz/${TARGET_PROJECT}:${TARGET_ARCH}
COPY --from=${SYMSAN_IMAGE} /opt/symsan/bin /opt/symsan/bin
ENV PATH="/opt/symsan/bin:/usr/lib/llvm-18/bin:${PATH}"
EOF

docker build -t "${COMPILE_IMAGE}" -f "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}" || {
    echo "ERROR: Failed to build compiler image for ${TARGET_PROJECT}"
    exit 1
}

# Run compilation inside the compiled image where ko-clang exists
docker run --rm \
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
    bash -c 'cd /src && ls -la build.sh *.fuzz.cpp 2>/dev/null || true && cat build.sh'

# Check if any binaries were produced
SYMSAN_BINARIES=$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -perm -111 ! -name '*.so' ! -name '*.a' 2>/dev/null | sort)

if [ -z "${SYMSAN_BINARIES}" ]; then
    echo "ERROR: No SymSan executable was produced."
    ls -la "${OUTPUT_DIR}/" || true
    exit 1
fi

echo "SymSan symbolic build completed successfully:"
echo "${SYMSAN_BINARIES}"

rm -rf "${DOCKERFILE_DIR}"
