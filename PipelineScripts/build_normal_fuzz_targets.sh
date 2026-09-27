#!/usr/bin/env bash
set -eux

project="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
engine="${2:-${TARGET_ENGINE:-libfuzzer}}"
sanitizer="${3:-${TARGET_SANITIZER:-address}}"
architecture="${4:-${TARGET_ARCH:-x86_64}}"

cd "${WORKSPACE:-$PWD}/oss-fuzz"

python3 infra/helper.py build_fuzzers \
    --engine="${engine}" \
    --sanitizer="${sanitizer}" \
    --architecture="${architecture}" \
    --clean \
    "${project}"
