#!/usr/bin/env bash
set -eux

export TARGET_PROJECT="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
export TARGET_ARCH="${2:-${TARGET_ARCH:-x86_64}}"

OSS_FUZZ_DIR="${WORKSPACE:-$PWD}/oss-fuzz"
PY_SCRIPT="/tmp/symsan_build_${TARGET_PROJECT}.py"

cat > "${PY_SCRIPT}" <<'PYTHON_EOF'
import os, sys
sys.path.insert(0, "infra")
import common_utils, helper

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
print("Building SymSan symbolic binary")
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
PYTHON_EOF

docker run --rm \
    -v "${OSS_FUZZ_DIR}:/src" \
    -v "${PY_SCRIPT}:/build.py" \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -e TARGET_PROJECT="${TARGET_PROJECT}" \
    -e TARGET_ARCH="${TARGET_ARCH}" \
    "${SYMSAN_IMAGE}" \
    bash -c 'cd /src && python3 /build.py'

rm -f "${PY_SCRIPT}"
