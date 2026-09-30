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

# Use locally-built project image (full gcr.io name, no arch tag suffix)
PROJECT_IMAGE="gcr.io/oss-fuzz/${TARGET_PROJECT}:latest"

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
        docker.io \
        && rm -rf /var/lib/apt/lists/*

# Bring ko-clang and ko-clang++ from the Symsan image
COPY --from=${SYMSAN_IMAGE} /opt/symsan/bin /opt/symsan/bin
ENV PATH="/opt/symsan/bin:/usr/lib/llvm-18/bin:${PATH}"
EOF

docker build -t "${COMPILE_IMAGE}" -f "${DOCKERFILE_DIR}/Dockerfile" "${DOCKERFILE_DIR}" || {
    echo "ERROR: Failed to build compiler image for ${TARGET_PROJECT}"
    exit 1
}

# Run compilation inside the compile image where ko-clang exists.
# Write python script to temp file (heredoc doesn't work inside docker run multi-line).
PY_SCRIPT="${OSS_FUZZ_DIR}/build/tmp_symsan_build_${TARGET_PROJECT}.py"

cat > "${PY_SCRIPT}" <<'PYEOF'
import os, sys

sys.path.insert(0, "/oss-fuzz/infra")

import common_utils
import helper

project_name = os.environ["TARGET_PROJECT"]
architecture = os.environ["TARGET_ARCH"]
project = common_utils.Project(project_name)

env = [
    "FUZZING_ENGINE=afl",
    "SANITIZER=none",
    "ARCHITECTURE=" + architecture,
    "PROJECT_NAME=" + project_name,
    "HELPER=True",
    "CC=/opt/symsan/bin/ko-clang",
    "CXX=/opt/symsan/bin/ko-clang++",
    "KO_CC=clang-18",
    "KO_CXX=clang++-18",
    "KO_USE_FASTGEN=1",
    "AFL_LLVM_CMPLOG=0",
]

print("========================================")
print("Building SymSan symbolic binary (via helper.py)")
print("Project:", project_name)
print("Architecture:", architecture)
print("========================================")

result = helper.build_fuzzers_impl(
    project=project,
    clean=True,
    engine="afl",
    sanitizer="none",
    architecture=architecture,
    env_to_add=env,
    source_path=None,
    child_dir="symsan",
    build_project_image=False,
)

if not result:
    raise SystemExit("SymSan symbolic build failed")

print("SymSan symbolic build completed successfully.")
PYEOF

docker run --rm \
    -v "${OSS_FUZZ_DIR}:/oss-fuzz" \
    -v "${PY_SCRIPT}:/symsan_build.py" \
    -e TARGET_PROJECT="${TARGET_PROJECT}" \
    -e TARGET_ARCH="${TARGET_ARCH}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "${COMPILE_IMAGE}" \
    python3 /symsan_build.py

rm -f "${PY_SCRIPT}"

# Check if any binaries were produced
SYMSAN_BINARIES=$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -perm -111 ! -name '*.so' ! -name '*.a' 2>/dev/null | sort)

if [ -z "${SYMSAN_BINARIES}" ]; then
    echo "ERROR: No SymSan executable was produced."
    ls -la "${OUTPUT_DIR}/" || true
    exit 1
fi

echo "SymSan symbolic build completed successfully:"
echo "${SYMSAN_BINARIES}"
