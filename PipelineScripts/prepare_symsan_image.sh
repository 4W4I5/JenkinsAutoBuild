#!/usr/bin/env bash
set -eux

project_image="gcr.io/oss-fuzz/${TARGET_PROJECT}"

rm -rf symsan-docker
mkdir -p symsan-docker

cat > symsan-docker/Dockerfile <<'EOF'
ARG PROJECT_IMAGE
FROM ${PROJECT_IMAGE} AS oss_fuzz_project

FROM ubuntu:24.04

COPY --from=oss_fuzz_project /src /src
COPY --from=oss_fuzz_project /out /out

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/lib/llvm-18/bin:$PATH"

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
        llvm-18 \
        llvm-18-dev \
        clang-18 \
        lld-18 \
        libclang-18-dev \
        libc++-18-dev \
        libc++abi-18-dev \
        libunwind-18-dev \
        gcc-13-plugin-dev \
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
# LLVM 18
# ----------------------------------------------------------------------
#
RUN clang-18 --version && \
    clang++-18 --version && \
    llvm-config-18 --version

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
    LLVM_CONFIG=llvm-config-18 \
    CC=clang-18 \
    CXX=clang++-18 \
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
    CC=clang-18 \
    CXX=clang++-18 \
    cmake \
        -DAFLPP_PATH=/opt/aflpp \
        -DCMAKE_C_COMPILER=clang-18 \
        -DCMAKE_CXX_COMPILER=clang++-18 \
        -DLLVM_DIR=/usr/lib/llvm-18/lib/cmake/llvm \
        -DCMAKE_INSTALL_PREFIX=/opt/symsan \
        -DCMAKE_BUILD_TYPE=Release \
        .. && \
    cmake --build . --parallel $(nproc) && \
    cmake --install .

RUN test -d /opt/symsan && \
    find /opt/symsan -maxdepth 3 -type f | sort

ENV SYMSAN_HOME=/opt/symsan
ENV AFLPP_HOME=/opt/aflpp

ENV PATH="/opt/symsan/bin:/opt/aflpp:/usr/lib/llvm-18/bin:$PATH"

ENV KO_CC=clang-18
ENV KO_CXX=clang++-18
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
    "${project_image}:symsan-llvm18"

echo

echo "========================================"
echo "SymSan LLVM 18 image"
echo "========================================"

docker image inspect \
    "${project_image}:latest" \
    --format '{{.Id}}'

echo
docker run --rm \
    "${project_image}:latest" \
    bash -c '
        echo "LLVM:"
        clang-18 --version
        echo
        echo "LLVM config:"
        llvm-config-18 --version
        echo
        echo "AFL++:"
        command -v afl-fuzz || true
        command -v afl-clang-fast || true
        echo
        echo "SymSan:"
        ls -la /opt/symsan/bin || true
    '
