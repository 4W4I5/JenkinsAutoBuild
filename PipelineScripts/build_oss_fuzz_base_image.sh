#!/usr/bin/env bash
set -eux

project="${1:-${TARGET_PROJECT:-libjpeg-turbo}}"
architecture="${2:-${TARGET_ARCH:-x86_64}}"

cd "${WORKSPACE:-$PWD}/oss-fuzz"

python3 infra/helper.py build_image \
    --pull \
    --architecture="${architecture}" \
    "${project}"
