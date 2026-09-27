#!/usr/bin/env bash
set -eux

project_out="${1:-oss-fuzz/build/out/${TARGET_PROJECT}}"

echo "========================================"
echo "Build output"
echo "========================================"

find "${project_out}" \
    -maxdepth 3 \
    -type f \
    -print \
    2>/dev/null || true

if [ "${ENABLE_SYMSAN:-false}" = "true" ]; then
    echo
    echo "========================================"
    echo "SymSan verification"
    echo "========================================"

    test -d "${project_out}/afl"
    test -d "${project_out}/symsan"

    test -f "${project_out}/symsan/libSymSanMutator.so"
    test -f "${project_out}/symsan/symsan.env"
    test -f "${project_out}/symsan/BUILD_INFO"

    echo
    echo "AFL++ executables:"
    find "${project_out}/afl" \
        -maxdepth 1 \
        -type f \
        -perm -111 \
        -print \
        2>/dev/null || true

    echo
    echo "SymSan executables:"
    find "${project_out}/symsan" \
        -maxdepth 1 \
        -type f \
        -perm -111 \
        ! -name 'libSymSanMutator.so' \
        -print \
        2>/dev/null || true

    echo
    echo "SymSan configuration:"
    cat "${project_out}/symsan/symsan.env"

    echo
    echo "SymSan build information:"
    cat "${project_out}/symsan/BUILD_INFO"
fi

echo

echo "========================================"
echo "Disk usage"
echo "========================================"

du -sh "${project_out}"/* 2>/dev/null || true
