#!/usr/bin/env bash
set -eux

project_image="gcr.io/oss-fuzz/${TARGET_PROJECT}"

rm -rf symsan-docker
mkdir -p symsan-docker

cat > symsan-docker/Dockerfile <<'EOF'
ARG PROJECT_IMAGE=gcr.io/oss-fuzz/libjpeg-turbo
FROM ${PROJECT_IMAGE} AS oss_fuzz_project

FROM ubuntu:24.04

COPY --from=oss_fuzz_project /src /src
COPY --from=oss_fuzz_project /out /out

USER root

ENV DEBIAN_FRONTEND=noninteractive

#
# ----------------------------------------------------------------------
# Basic build dependencies
# ----------------------------------------------------------------------
#
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget \
        curl \
        git \
        cmake \
        ninja-build \
        build-essential \
        lsb-release \
        software-properties-common \
        gnupg \
        python3 \
        python3-dev \
        python3-pip \
        zlib1g-dev \
        libz3-dev \
        libgoogle-perftools-dev \
        gdb \
        ca-certificates \
        pkg-config \
        unzip \
        rsync \
        sshpass \
        && \
    rm -rf /var/lib/apt/lists/*

#
# ----------------------------------------------------------------------
# LLVM 22
# ----------------------------------------------------------------------
#
ARG LLVM_RELEASE=22.1.0

RUN mkdir -p /opt/llvm-22 && \
    curl -fsSL \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_RELEASE}/LLVM-${LLVM_RELEASE}-Linux-X64.tar.xz" \
        -o /tmp/llvm.tar.xz && \
    tar -xJf /tmp/llvm.tar.xz \
        --strip-components=1 \
        -C /opt/llvm-22 && \
    rm -f /tmp/llvm.tar.xz && \
    for tool in clang clang++ llvm-config lld ld.lld; do \
        if [ -x "/opt/llvm-22/bin/${tool}" ]; then \
            ln -s "/opt/llvm-22/bin/${tool}" "/usr/local/bin/${tool}-22"; \
        fi; \
    done

RUN clang-22 --version && \
    clang++-22 --version && \
    llvm-config-22 --version

#
# ----------------------------------------------------------------------
# AFL++
# ----------------------------------------------------------------------
#
RUN rm -rf /opt/aflpp && \
    git clone --depth=1 \
        https://github.com/AFLplusplus/AFLplusplus.git \
        /opt/aflpp

RUN cd /opt/aflpp && \
    make clean || true

RUN cd /opt/aflpp && \
    LLVM_CONFIG=llvm-config-22 \
    CC=clang-22 \
    CXX=clang++-22 \
    make source-only -j$(nproc)

RUN cd /opt/aflpp && \
    make install

RUN command -v afl-clang-fast && \
    command -v afl-clang-fast++ && \
    afl-clang-fast --version || true

#
# ----------------------------------------------------------------------
# SymSan
# ----------------------------------------------------------------------
#
RUN rm -rf /opt/symsan-src && \
    git clone --depth=1 \
        https://github.com/R-Fuzz/symsan.git \
        /opt/symsan-src

RUN mkdir -p /opt/symsan-src/build && \
    cd /opt/symsan-src/build && \
    CC=clang-22 \
    CXX=clang++-22 \
    cmake \
        -DAFLPP_PATH=/opt/aflpp \
        -DCMAKE_C_COMPILER=clang-22 \
        -DCMAKE_CXX_COMPILER=clang++-22 \
        -DLLVM_DIR=/opt/llvm-22/lib/cmake/llvm \
        -DCMAKE_INSTALL_PREFIX=/opt/symsan \
        -DCMAKE_BUILD_TYPE=Release \
        .. && \
    cmake --build . --parallel $(nproc) && \
    cmake --install .

RUN test -d /opt/symsan && \
    find /opt/symsan -maxdepth 3 -type f | sort

ENV SYMSAN_HOME=/opt/symsan
ENV AFLPP_HOME=/opt/aflpp

ENV PATH="/opt/symsan/bin:/opt/aflpp:/usr/lib/llvm-22/bin:$PATH"

ENV KO_CC=clang-22
ENV KO_CXX=clang++-22
ENV KO_USE_FASTGEN=1
ENV AFL_LLVM_CMPLOG=0

USER root
EOF

docker build \
    --pull \
    --build-arg "PROJECT_IMAGE=${project_image}" \
    -f symsan-docker/Dockerfile \
    -t "${SYMSAN_IMAGE}" \
    .

docker tag \
    "${SYMSAN_IMAGE}" \
    "${project_image}:latest"

docker tag \
    "${SYMSAN_IMAGE}" \
    "${project_image}:symsan-llvm22"

echo

echo "========================================"
echo "SymSan LLVM 22 image"
echo "========================================"

docker image inspect \
    "${project_image}:latest" \
    --format '{{.Id}}'

echo
docker run --rm \
    "${project_image}:latest" \
    bash -c '
        echo "LLVM:"
        clang-22 --version
        echo
        echo "LLVM config:"
        llvm-config-22 --version
        echo
        echo "AFL++:"
        command -v afl-fuzz || true
        command -v afl-clang-fast || true
        echo
        echo "SymSan:"
        ls -la /opt/symsan/bin || true
    '
