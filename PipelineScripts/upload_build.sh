#!/usr/bin/env bash
set -eux

if [ "${ENABLE_SYMSAN:-false}" = "true" ]; then
    BUILD_MODE="symsan_aflpp_llvm22"
else
    BUILD_MODE="${TARGET_ENGINE}_${TARGET_SANITIZER}"
fi

LOCAL_OUT="oss-fuzz/build/out/${TARGET_PROJECT}"
REMOTE_DIR="/home/ubuntu24/oss-fuzz/build/out/${TARGET_PROJECT}_${BUILD_MODE}"

echo "Local output : ${LOCAL_OUT}"
echo "Remote output: ${REMOTE_DIR}"

sshpass -p "${REMOTE_PASS}" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    "mkdir -p '${REMOTE_DIR}'"

sshpass -p "${REMOTE_PASS}" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    "rm -rf '${REMOTE_DIR:?}'/*"

sshpass -p "${REMOTE_PASS}" scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -r \
    "${LOCAL_OUT}/"* \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"

echo

echo "========================================"
echo "Remote upload completed"
echo "========================================"

sshpass -p "${REMOTE_PASS}" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${REMOTE_USER}@${REMOTE_HOST}" \
    "find '${REMOTE_DIR}' -maxdepth 3 -type f -print | sort"
