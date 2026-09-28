#!/usr/bin/env bash
set -eux

export TARGET_PROJECT="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
export TARGET_ARCH="${2:-${TARGET_ARCH:-x86_64}}"

OSS_FUZZ_DIR="${WORKSPACE:-$PWD}/oss-fuzz"

echo "========================================"
echo "Building SymSan symbolic binary"
echo "Project: ${TARGET_PROJECT}"
echo "Architecture: ${TARGET_ARCH}"
echo "========================================"

docker run --rm \
    -v "${OSS_FUZZ_DIR}:/src" \
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
    "${SYMSAN_IMAGE}" \
    python3 /src/infra/helper.py build_fuzzers \
        --engine afl \
        --clean \
        --architecture "${TARGET_ARCH}" \
        --no-fuzzing-engine-build \
        --no-sanitizer-build \
        --project "${TARGET_PROJECT}" \
        --child-dir symsan

echo "SymSan symbolic build completed successfully."
