#!/usr/bin/env bash
set -eux

project_out="${1:-oss-fuzz/build/out/${TARGET_PROJECT}}"
symsan_out="${2:-${project_out}/symsan}"
afl_out="${3:-${project_out}/afl}"

mkdir -p "${symsan_out}"

echo "========================================"
echo "Locating SymSan custom mutator"
echo "========================================"

docker run --rm \
    -v "${WORKSPACE}/${project_out}:/export" \
    "${SYMSAN_IMAGE}" \
    bash -c '
        set -eux

        MUTATOR=$(find /opt/symsan \
            -type f \
            -name "libSymSanMutator.so" \
            | head -1)

        if [ -z "${MUTATOR}" ]; then
            echo "ERROR: libSymSanMutator.so not found."
            echo
            echo "Installed SymSan files:"
            find /opt/symsan -type f | sort
            exit 1
        fi

        echo "Found mutator:"
        echo "${MUTATOR}"

        mkdir -p /export/symsan

        cp "${MUTATOR}" \
           /export/symsan/libSymSanMutator.so

        chmod 755 \
            /export/symsan/libSymSanMutator.so
    '

test -f "${symsan_out}/libSymSanMutator.so"

AFL_TARGETS=$(find "${afl_out}" \
    -maxdepth 1 \
    -type f \
    -perm -111 \
    ! -name '*.so' \
    ! -name '*.a' \
    | sort || true)

echo

echo "AFL++ executable candidates:"
echo "${AFL_TARGETS}"

SYMSAN_TARGETS=$(find "${symsan_out}" \
    -maxdepth 1 \
    -type f \
    -perm -111 \
    ! -name '*.so' \
    ! -name '*.a' \
    ! -name 'libSymSanMutator.so' \
    | sort || true)

echo

echo "SymSan executable candidates:"
echo "${SYMSAN_TARGETS}"

if [ -z "${SYMSAN_TARGETS}" ]; then
    echo
    echo "ERROR: No SymSan executable was produced."
    exit 1
fi

SYMSAN_TARGET=""
while IFS= read -r candidate; do
    [ -z "${candidate}" ] && continue

    NAME=$(basename "${candidate}")

    if [ -f "${afl_out}/${NAME}" ]; then
        SYMSAN_TARGET="${candidate}"
        break
    fi
done <<EOF
${SYMSAN_TARGETS}
EOF

if [ -z "${SYMSAN_TARGET}" ]; then
    SYMSAN_TARGET=$(printf '%s\n' "${SYMSAN_TARGETS}" | head -1)
fi

SYMSAN_TARGET_NAME=$(basename "${SYMSAN_TARGET}")

echo

echo "Selected SymSan target:"
echo "${SYMSAN_TARGET}"

cat > "${symsan_out}/symsan.env" <<EOF
AFL_CUSTOM_MUTATOR_LIBRARY=\$PWD/libSymSanMutator.so
SYMSAN_TARGET=\$PWD/${SYMSAN_TARGET_NAME}
AFL_DISABLE_TRIM=1
EOF

cat > "${symsan_out}/BUILD_INFO" <<EOF
PROJECT=${TARGET_PROJECT}
ARCHITECTURE=${TARGET_ARCH}
LLVM_VERSION=18
FUZZING_ENGINE=afl
SYMSAN_ENABLED=true
AFL_TARGET_DIRECTORY=../afl
SYMSAN_TARGET_DIRECTORY=.
SYMSAN_TARGET=${SYMSAN_TARGET_NAME}
EOF

echo

echo "========================================"
echo "SymSan runtime bundle"
echo "========================================"

cat "${symsan_out}/symsan.env"
echo
cat "${symsan_out}/BUILD_INFO"
