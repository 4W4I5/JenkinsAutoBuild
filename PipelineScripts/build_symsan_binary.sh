#!/usr/bin/env bash
set -eux

export TARGET_PROJECT="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
export TARGET_ARCH="${2:-${TARGET_ARCH:-x86_64}}"

OSS_FUZZ_DIR="${WORKSPACE:-$PWD}/oss-fuzz"
PROJECT_DIR="${OSS_FUZZ_DIR}/projects/${TARGET_PROJECT}"
BASE_OUT_DIR="${OSS_FUZZ_DIR}/build/out/${TARGET_PROJECT}"
OUTPUT_DIR="${BASE_OUT_DIR}/symsan"
SYMSAN_IMAGE="${3:-${SYMSAN_IMAGE:-oss-fuzz-symsan-latest}}"

mkdir -p "${OUTPUT_DIR}"

echo "========================================"
echo "Building SymSan symbolic binary"
echo "Project: ${TARGET_PROJECT}"
echo "Architecture: ${TARGET_ARCH}"
echo "========================================"

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
ENV PATH="/usr/lib/llvm-18/bin:/opt/symsan/bin:\${PATH}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 python3-dev python-is-python3 gcc g++ make cmake \
        libc6-dev libstdc++-13-dev zlib1g-dev ca-certificates docker.io \
        && rm -rf /var/lib/apt/lists/*

COPY --from=${SYMSAN_IMAGE} /opt/symsan/bin /opt/symsan/bin

ENV PATH="/opt/symsan/bin:/usr/lib/llvm-18/bin:\${PATH}"
EOF

docker build \
    -t "${COMPILE_IMAGE}" \
    -f "${DOCKERFILE_DIR}/Dockerfile" \
    "${DOCKERFILE_DIR}" || {
        echo "ERROR: Failed to build compiler image for ${TARGET_PROJECT}"
        exit 1
    }

PY_SCRIPT="${OSS_FUZZ_DIR}/build/tmp_symsan_build_${TARGET_PROJECT}.py"

cat > "${PY_SCRIPT}" <<'PYEOF'
import os
import sys

sys.path.insert(0, "/oss-fuzz/infra")

import common_utils
import helper

project_name = os.environ["TARGET_PROJECT"]
architecture = os.environ["TARGET_ARCH"]

project = common_utils.Project(project_name)

print("========================================")
print("DEBUG: OSS-FUZZ PROJECT PATHS")
print("========================================")
print("CWD:", os.getcwd())
print("Project path:", project.path)
print("Project out:", project.out)
print("Project work:", project.work)
print("Project out exists:", os.path.exists(project.out))
print("Project work exists:", os.path.exists(project.work))

print("\n=== project.out ===")
os.system("find '" + project.out + "' -maxdepth 4 -ls 2>/dev/null || true")

print("\n=== /oss-fuzz/build/out ===")
os.system("find /oss-fuzz/build/out -maxdepth 5 -ls 2>/dev/null || true")

print("\n=== /out ===")
os.system("find /out -maxdepth 5 -ls 2>/dev/null || true")

print("\n=== /work ===")
os.system("find /work -maxdepth 5 -ls 2>/dev/null || true")

print("========================================")

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

print("========================================")
print("SymSan symbolic build completed successfully.")
print("========================================")

print("\n=== OUTPUT AFTER HELPER ===")
print("project.out:", project.out)
print("project.work:", project.work)

os.system(
    "find '" + project.out + "' "
    "-maxdepth 5 "
    "-type f "
    "-ls 2>/dev/null || true"
)

print("\n=== EXECUTABLES AFTER HELPER ===")
os.system(
    "find '" + project.out + "' "
    "-type f "
    "-perm -111 "
    "-ls 2>/dev/null || true"
)

print("\n=== ELF-LIKE FILES AFTER HELPER ===")
os.system(
    "find '" + project.out + "' "
    "-type f "
    "-exec file {} \\; "
    "2>/dev/null | grep -E 'ELF|executable' || true"
)
PYEOF

echo "========================================"
echo "Running SymSan helper"
echo "========================================"

docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${OSS_FUZZ_DIR}:/oss-fuzz" \
    -v "${OSS_FUZZ_DIR}:${OSS_FUZZ_DIR}" \
    -v "${PY_SCRIPT}:/symsan_build.py" \
    -e TARGET_PROJECT="${TARGET_PROJECT}" \
    -e TARGET_ARCH="${TARGET_ARCH}" \
    "${COMPILE_IMAGE}" \
    python3 /symsan_build.py

# ============================================================
# DEBUG PAUSE
# ============================================================

echo ""
echo "============================================================"
echo "DEBUG: SymSan helper.py has returned successfully"
echo "============================================================"

echo ""
echo "HOST WORKSPACE:"
echo "  ${WORKSPACE:-$PWD}"

echo ""
echo "OSS-FUZZ DIR:"
echo "  ${OSS_FUZZ_DIR}"

echo ""
echo "BASE OUTPUT:"
echo "  ${BASE_OUT_DIR}"

echo ""
echo "SYMSAN OUTPUT:"
echo "  ${OUTPUT_DIR}"

echo ""
echo "============================================================"
echo "DEBUG: BASE OUTPUT CONTENTS"
echo "============================================================"

find "${BASE_OUT_DIR}" \
    -maxdepth 5 \
    -ls \
    2>/dev/null || true

echo ""
echo "============================================================"
echo "DEBUG: SYMSAN OUTPUT CONTENTS"
echo "============================================================"

find "${OUTPUT_DIR}" \
    -maxdepth 5 \
    -ls \
    2>/dev/null || true

echo ""
echo "============================================================"
echo "DEBUG: ALL EXECUTABLES IN PROJECT OUTPUT"
echo "============================================================"

find "${BASE_OUT_DIR}" \
    -type f \
    -perm -111 \
    -ls \
    2>/dev/null || true

echo ""
echo "============================================================"
echo "DEBUG: ALL FILES IN PROJECT OUTPUT"
echo "============================================================"

find "${BASE_OUT_DIR}" \
    -type f \
    -exec file {} \; \
    2>/dev/null || true

echo ""
echo "============================================================"
echo "DEBUG: RECENT FILES IN OSS-FUZZ"
echo "============================================================"

find "${OSS_FUZZ_DIR}" \
    -type f \
    -mmin -30 \
    -printf '%TY-%Tm-%Td %TH:%TM:%TS %u:%g %p\n' \
    2>/dev/null \
    | sort \
    | tail -200 || true

echo ""
echo "============================================================"
echo "DEBUG: GENERATED PYTHON SCRIPT"
echo "============================================================"

cat "${PY_SCRIPT}" || true

echo ""
echo "============================================================"
echo "DEBUG PAUSE"
echo "============================================================"
echo "The SymSan helper has completed."
echo ""
echo "You can now SSH into the Jenkins machine and inspect:"
echo ""
echo "  ${OSS_FUZZ_DIR}"
echo "  ${BASE_OUT_DIR}"
echo "  ${OUTPUT_DIR}"
echo ""
echo "The temporary Python script has NOT been deleted."
echo ""
echo "Press ENTER here to continue."
echo "============================================================"

read -r

echo ""
echo "Continuing SymSan post-processing..."

# Keep the generated Python script until after debugging.
rm -f "${PY_SCRIPT}"

# ============================================================
# POST-PROCESSING
# ============================================================

# Fix 1:
# If binaries were dumped in base output dir instead of symsan
# subfolder, move them over.
if [ -d "${BASE_OUT_DIR}" ]; then
    find "${BASE_OUT_DIR}" \
        -maxdepth 1 \
        -type f \
        ! -name '*.so' \
        ! -name '*.a' \
        -exec cp -f {} "${OUTPUT_DIR}/" \; \
        2>/dev/null || true
fi

# Fix 2:
# Explicitly grant execution permissions.
chmod -R +x "${OUTPUT_DIR}" || true

# Fix 3:
# Find SymSan output files.
SYMSAN_BINARIES=$(
    find "${OUTPUT_DIR}" \
        -type f \
        ! -name '*.so' \
        ! -name '*.a' \
        ! -name '*.env' \
        ! -name 'BUILD_INFO' \
        2>/dev/null \
        | sort
)

if [ -z "${SYMSAN_BINARIES}" ]; then
    echo ""
    echo "============================================================"
    echo "ERROR: No SymSan executable was produced."
    echo "============================================================"

    echo ""
    echo "Contents of base output directory:"
    ls -la "${BASE_OUT_DIR}/" || true

    echo ""
    echo "Contents of SymSan output directory:"
    ls -la "${OUTPUT_DIR}/" || true

    echo ""
    echo "Full output tree:"
    find "${BASE_OUT_DIR}" -maxdepth 5 -ls || true

    exit 1
fi

echo ""
echo "============================================================"
echo "SymSan symbolic build completed successfully"
echo "============================================================"
echo "${SYMSAN_BINARIES}"
