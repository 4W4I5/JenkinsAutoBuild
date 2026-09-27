#!/usr/bin/env bash
set -eux

export TARGET_PROJECT="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
export TARGET_ARCH="${2:-${TARGET_ARCH:-x86_64}}"

cd "${WORKSPACE:-$PWD}/oss-fuzz"

python3 - <<'PY'
import os
import sys

sys.path.insert(0, "infra")

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
    "CC=afl-clang-fast",
    "CXX=afl-clang-fast++",
    "AFL_LLVM_CMPLOG=0",
]

print("========================================")
print("Building normal AFL++ binary")
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
    child_dir="afl",
    build_project_image=False,
)

if not result:
    raise SystemExit("Normal AFL++ build failed")

print("Normal AFL++ build completed successfully.")
PY
