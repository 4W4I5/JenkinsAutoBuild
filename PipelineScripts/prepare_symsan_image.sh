#!/usr/bin/env bash
set -eux

project_image="gcr.io/oss-fuzz/${TARGET_PROJECT}"

rm -rf symsan-docker
mkdir -p symsan-docker

cat > symsan-docker/Dockerfile <<'EOF'
ARG PROJECT_IMAGE
FROM ${PROJECT_IMAGE}

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
RUN wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh && \
    chmod +x /tmp/llvm.sh && \
    /tmp/llvm.sh 22 all && \
    rm -f /tmp/llvm.sh

RUN clang-22 --version && \
    clang++-22 --version && \
    llvm-config-22 --version

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libc++-22-dev \
        libc++abi-22-dev \
        libunwind-22-dev \
        lld-22 \
        && \
    rm -rf /var/lib/apt/lists/*

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
        -DLLVM_DIR=$(llvm-config-22 --cmakedir) \
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
