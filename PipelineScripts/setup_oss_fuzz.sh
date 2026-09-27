#!/usr/bin/env bash
set -eux

repo="${1:-${OSS_FUZZ_REPO:-https://github.com/google/oss-fuzz.git}}"
workspace="${WORKSPACE:-$PWD}"
target_dir="${2:-${workspace}/oss-fuzz}"

mkdir -p "${workspace}"

if [ ! -d "${target_dir}/.git" ]; then
    git clone --depth=1 "${repo}" "${target_dir}"
else
    cd "${target_dir}"
    git fetch origin
    git reset --hard origin/HEAD
    cd - >/dev/null
fi
