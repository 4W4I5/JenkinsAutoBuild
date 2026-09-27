pipeline {
    agent any

    parameters {
        string(
            name: 'TARGET_PROJECT',
            defaultValue: 'libjpeg-turbo',
            description: 'OSS-Fuzz project name'
        )

        choice(
            name: 'TARGET_SANITIZER',
            choices: ['address', 'undefined', 'memory', 'thread'],
            description: 'OSS-Fuzz sanitizer for normal builds'
        )

        choice(
            name: 'TARGET_ENGINE',
            choices: ['libfuzzer', 'afl', 'honggfuzz'],
            description: 'OSS-Fuzz engine for normal builds'
        )

        string(
            name: 'TARGET_ARCH',
            defaultValue: 'x86_64',
            description: 'OSS-Fuzz architecture'
        )

        booleanParam(
            name: 'ENABLE_SYMSAN',
            defaultValue: false,
            description: 'Enable SymSan hybrid fuzzing. Builds normal AFL++ + SymSan symbolic binaries.'
        )
    }

    environment {
        OSS_FUZZ_REPO = 'https://github.com/google/oss-fuzz.git'
        SYMSAN_REPO = 'https://github.com/R-Fuzz/symsan.git'
        AFLPP_REPO = 'https://github.com/AFLplusplus/AFLplusplus.git'

        /*
         * LLVM 22 is requested for this pipeline.
         *
         * IMPORTANT:
         * Upstream SymSan currently documents/tests LLVM 18.
         * LLVM 22 therefore needs to be compatible with your SymSan
         * checkout/fork.
         */
        LLVM_VERSION = '22'

        REMOTE_HOST = '192.168.18.56'
        REMOTE_USER = 'ubuntu24'
        REMOTE_PASS = 'admin'

        SYMSAN_IMAGE = "oss-fuzz-symsan-${BUILD_NUMBER}"
        SYMSAN_HOME = '/opt/symsan'
        AFLPP_HOME = '/opt/aflpp'
    }

    stages {

        stage('Set Build Name') {
            steps {
                script {
                    if (params.ENABLE_SYMSAN) {
                        currentBuild.displayName =
                            "${params.TARGET_PROJECT}_symsan_aflpp_llvm22"
                    } else {
                        currentBuild.displayName =
                            "${params.TARGET_PROJECT}_${params.TARGET_ENGINE}_${params.TARGET_SANITIZER}"
                    }
                }
            }
        }

        stage('Setup OSS-Fuzz Environment') {
            steps {
                sh '''
                    set -eux

                    if [ ! -d "oss-fuzz/.git" ]; then
                        git clone --depth=1 "${OSS_FUZZ_REPO}" oss-fuzz
                    else
                        cd oss-fuzz

                        git fetch origin
                        git reset --hard origin/master

                        cd ..
                    fi
                '''
            }
        }

        stage('Build OSS-Fuzz Base Image') {
            steps {
                sh """
                    set -eux

                    cd oss-fuzz

                    python3 infra/helper.py build_image \
                        --pull \
                        --architecture=${params.TARGET_ARCH} \
                        ${params.TARGET_PROJECT}
                """
            }
        }

        /*
         * ================================================================
         * SymSan image
         * ================================================================
         *
         * The image contains:
         *
         *   - LLVM/Clang 22
         *   - AFL++
         *   - SymSan
         *
         * helper.py subsequently uses:
         *
         *   gcr.io/oss-fuzz/<project>
         *
         * so the generated image is tagged with that name.
         */
        stage('Prepare SymSan + AFL++ LLVM 22 Image') {
            when {
                expression {
                    return params.ENABLE_SYMSAN
                }
            }

            steps {
                sh """
                    set -eux

                    PROJECT_IMAGE="gcr.io/oss-fuzz/${params.TARGET_PROJECT}"

                    rm -rf symsan-docker
                    mkdir -p symsan-docker

                    cat > symsan-docker/Dockerfile <<'EOF'
FROM gcr.io/oss-fuzz/${params.TARGET_PROJECT}

USER root

ENV DEBIAN_FRONTEND=noninteractive

#
# ----------------------------------------------------------------------
# Basic build dependencies
# ----------------------------------------------------------------------
#
RUN apt-get update && \\
    apt-get install -y --no-install-recommends \\
        wget \\
        curl \\
        git \\
        cmake \\
        ninja-build \\
        build-essential \\
        lsb-release \\
        software-properties-common \\
        gnupg \\
        python3 \\
        python3-dev \\
        python3-pip \\
        zlib1g-dev \\
        libz3-dev \\
        libgoogle-perftools-dev \\
        gdb \\
        ca-certificates \\
        pkg-config \\
        unzip \\
        rsync \\
        sshpass \\
        && \\
    rm -rf /var/lib/apt/lists/*

#
# ----------------------------------------------------------------------
# LLVM 22
# ----------------------------------------------------------------------
#
# Use the official LLVM installation script.
#
RUN wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh && \\
    chmod +x /tmp/llvm.sh && \\
    /tmp/llvm.sh 22 all && \\
    rm -f /tmp/llvm.sh

#
# Explicit LLVM 22 verification.
#
RUN clang-22 --version && \\
    clang++-22 --version && \\
    llvm-config-22 --version

#
# Install LLVM 22 libc++ development packages.
#
RUN apt-get update && \\
    apt-get install -y --no-install-recommends \\
        libc++-22-dev \\
        libc++abi-22-dev \\
        libunwind-22-dev \\
        lld-22 \\
        && \\
    rm -rf /var/lib/apt/lists/*

#
# ----------------------------------------------------------------------
# AFL++
# ----------------------------------------------------------------------
#
RUN rm -rf /opt/aflpp && \\
    git clone --depth=1 \\
        https://github.com/AFLplusplus/AFLplusplus.git \\
        /opt/aflpp

RUN cd /opt/aflpp && \\
    make clean || true

RUN cd /opt/aflpp && \\
    LLVM_CONFIG=llvm-config-22 \\
    CC=clang-22 \\
    CXX=clang++-22 \\
    make source-only -j\$(nproc)

RUN cd /opt/aflpp && \\
    make install

#
# Verify AFL++ LLVM instrumentation.
#
RUN command -v afl-clang-fast && \\
    command -v afl-clang-fast++ && \\
    afl-clang-fast --version || true

#
# ----------------------------------------------------------------------
# SymSan
# ----------------------------------------------------------------------
#
RUN rm -rf /opt/symsan-src && \\
    git clone --depth=1 \\
        https://github.com/R-Fuzz/symsan.git \\
        /opt/symsan-src

#
# Build SymSan against LLVM 22.
#
RUN mkdir -p /opt/symsan-src/build && \\
    cd /opt/symsan-src/build && \\
    CC=clang-22 \\
    CXX=clang++-22 \\
    cmake \\
        -DAFLPP_PATH=/opt/aflpp \\
        -DCMAKE_C_COMPILER=clang-22 \\
        -DCMAKE_CXX_COMPILER=clang++-22 \\
        -DLLVM_DIR=\$(llvm-config-22 --cmakedir) \\
        -DCMAKE_INSTALL_PREFIX=/opt/symsan \\
        -DCMAKE_BUILD_TYPE=Release \\
        .. && \\
    cmake --build . --parallel \$(nproc) && \\
    cmake --install .

#
# Verify SymSan installation.
#
RUN test -d /opt/symsan && \\
    find /opt/symsan -maxdepth 3 -type f | sort

#
# ----------------------------------------------------------------------
# Environment
# ----------------------------------------------------------------------
#
ENV SYMSAN_HOME=/opt/symsan
ENV AFLPP_HOME=/opt/aflpp

ENV PATH="/opt/symsan/bin:/opt/aflpp:/usr/lib/llvm-22/bin:\\$PATH"

ENV KO_CC=clang-22
ENV KO_CXX=clang++-22

#
# Out-of-process solving.
#
ENV KO_USE_FASTGEN=1

#
# SymSan itself handles the comparison/symbolic side.
#
ENV AFL_LLVM_CMPLOG=0

USER root
EOF

                    docker build \
                        --pull \
                        -f symsan-docker/Dockerfile \
                        -t "${SYMSAN_IMAGE}" \
                        .

                    #
                    # helper.py always runs:
                    #
                    #   gcr.io/oss-fuzz/<project>
                    #
                    # Therefore make the SymSan image available under
                    # that exact image name.
                    #
                    docker tag \
                        "${SYMSAN_IMAGE}" \
                        "${PROJECT_IMAGE}:latest"

                    docker tag \
                        "${SYMSAN_IMAGE}" \
                        "${PROJECT_IMAGE}:symsan-llvm22"

                    echo
                    echo "========================================"
                    echo "SymSan LLVM 22 image"
                    echo "========================================"

                    docker image inspect \
                        "${PROJECT_IMAGE}:latest" \
                        --format '{{.Id}}'

                    echo
                    docker run --rm \
                        "${PROJECT_IMAGE}:latest" \
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
                """
            }
        }

        /*
         * ================================================================
         * NORMAL MODE
         * ================================================================
         *
         * This is intentionally kept as the normal OSS-Fuzz build.
         */
        stage('Compile Normal Fuzz Targets') {
            when {
                expression {
                    return !params.ENABLE_SYMSAN
                }
            }

            steps {
                sh """
                    set -eux

                    cd oss-fuzz

                    python3 infra/helper.py build_fuzzers \
                        --engine=${params.TARGET_ENGINE} \
                        --sanitizer=${params.TARGET_SANITIZER} \
                        --architecture=${params.TARGET_ARCH} \
                        --clean \
                        ${params.TARGET_PROJECT}
                """
            }
        }

        /*
         * ================================================================
         * SYMSAN MODE - NORMAL AFL++ BINARY
         * ================================================================
         *
         * Output:
         *
         *   build/out/<project>/afl/
         */
        stage('SymSan - Build AFL++ Fuzzing Binary') {
            when {
                expression {
                    return params.ENABLE_SYMSAN
                }
            }

            steps {
                sh """
                    set -eux

                    cd oss-fuzz

                    python3 - <<'PY'
import sys

sys.path.insert(0, "infra")

import common_utils
import helper

project_name = "${params.TARGET_PROJECT}"
architecture = "${params.TARGET_ARCH}"

project = common_utils.Project(project_name)

env = [
    "FUZZING_ENGINE=afl",
    "SANITIZER=none",
    "ARCHITECTURE=" + architecture,
    "PROJECT_NAME=" + project_name,
    "HELPER=True",

    #
    # Normal AFL++ instrumentation.
    #
    "CC=afl-clang-fast",
    "CXX=afl-clang-fast++",

    #
    # Do not use AFL++ cmplog because SymSan's custom mutator /
    # symbolic analysis handles comparisons.
    #
    "AFL_LLVM_CMPLOG=0",
]

print("========================================")
print("Building normal AFL++ binary")
print("Project:", project_name)
print("Architecture:", architecture)
print("========================================")

result = helper.build_fuzzers_impl(
    project=project,
    clean=True,
    engine="afl",
    sanitizer="none",
    architecture=architecture,
    env_to_add=env,
    source_path=None,
    child_dir="afl",
    build_project_image=False,
)

if not result:
    raise SystemExit("Normal AFL++ build failed")

print("Normal AFL++ build completed successfully.")
PY
                """
            }
        }

        /*
         * ================================================================
         * SYMSAN MODE - SYMBOLIC BINARY
         * ================================================================
         *
         * Output:
         *
         *   build/out/<project>/symsan/
         *
         * This binary is NOT the binary AFL++ directly fuzzes.
         * It is the symbolic/instrumented target used by SymSan.
         */
        stage('SymSan - Build Symbolic Binary') {
            when {
                expression {
                    return params.ENABLE_SYMSAN
                }
            }

            steps {
                sh """
                    set -eux

                    cd oss-fuzz

                    python3 - <<'PY'
import sys

sys.path.insert(0, "infra")

import common_utils
import helper

project_name = "${params.TARGET_PROJECT}"
architecture = "${params.TARGET_ARCH}"

project = common_utils.Project(project_name)

env = [
    "FUZZING_ENGINE=afl",
    "SANITIZER=none",
    "ARCHITECTURE=" + architecture,
    "PROJECT_NAME=" + project_name,
    "HELPER=True",

    #
    # SymSan compiler wrappers.
    #
    "CC=/opt/symsan/bin/ko-clang",
    "CXX=/opt/symsan/bin/ko-clang++",

    #
    # LLVM 22 underneath SymSan.
    #
    "KO_CC=clang-22",
    "KO_CXX=clang++-22",

    #
    # Out-of-process solver.
    #
    "KO_USE_FASTGEN=1",

    #
    # SymSan handles symbolic comparison processing.
    #
    "AFL_LLVM_CMPLOG=0",
]

print("========================================")
print("Building SymSan symbolic binary")
print("Project:", project_name)
print("Architecture:", architecture)
print("========================================")

result = helper.build_fuzzers_impl(
    project=project,
    clean=True,
    engine="afl",
    sanitizer="none",
    architecture=architecture,
    env_to_add=env,
    source_path=None,
    child_dir="symsan",
    build_project_image=False,
)

if not result:
    raise SystemExit("SymSan symbolic build failed")

print("SymSan symbolic build completed successfully.")
PY
                """
            }
        }

        /*
         * ================================================================
         * PREPARE SYMSAN RUNTIME
         * ================================================================
         */
        stage('Prepare SymSan Runtime Bundle') {
            when {
                expression {
                    return params.ENABLE_SYMSAN
                }
            }

            steps {
                sh """
                    set -eux

                    PROJECT_OUT="oss-fuzz/build/out/${params.TARGET_PROJECT}"
                    SYMSAN_OUT="\${PROJECT_OUT}/symsan"
                    AFL_OUT="\${PROJECT_OUT}/afl"

                    mkdir -p "\${SYMSAN_OUT}"

                    echo "========================================"
                    echo "Locating SymSan custom mutator"
                    echo "========================================"

                    #
                    # The SymSan mutator is inside the image.
                    # Do NOT search the Jenkins host filesystem.
                    #
                    docker run --rm \
                        -v "\${WORKSPACE}/\${PROJECT_OUT}:/export" \
                        "${SYMSAN_IMAGE}" \
                        bash -c '
                            set -eux

                            MUTATOR=\$(find /opt/symsan \
                                -type f \
                                -name "libSymSanMutator.so" \
                                | head -1)

                            if [ -z "\${MUTATOR}" ]; then
                                echo "ERROR: libSymSanMutator.so not found."
                                echo
                                echo "Installed SymSan files:"
                                find /opt/symsan -type f | sort
                                exit 1
                            fi

                            echo "Found mutator:"
                            echo "\${MUTATOR}"

                            mkdir -p /export/symsan

                            cp "\${MUTATOR}" \
                               /export/symsan/libSymSanMutator.so

                            chmod 755 \
                                /export/symsan/libSymSanMutator.so
                        '

                    test -f \
                        "\${SYMSAN_OUT}/libSymSanMutator.so"

                    #
                    # Find actual AFL++ fuzz targets.
                    #
                    AFL_TARGETS=\$(find "\${AFL_OUT}" \
                        -maxdepth 1 \
                        -type f \
                        -perm -111 \
                        ! -name '*.so' \
                        ! -name '*.a' \
                        | sort || true)

                    echo
                    echo "AFL++ executable candidates:"
                    echo "\${AFL_TARGETS}"

                    #
                    # Find symbolic targets.
                    #
                    SYMSAN_TARGETS=\$(find "\${SYMSAN_OUT}" \
                        -maxdepth 1 \
                        -type f \
                        -perm -111 \
                        ! -name '*.so' \
                        ! -name '*.a' \
                        ! -name 'libSymSanMutator.so' \
                        | sort || true)

                    echo
                    echo "SymSan executable candidates:"
                    echo "\${SYMSAN_TARGETS}"

                    if [ -z "\${SYMSAN_TARGETS}" ]; then
                        echo
                        echo "ERROR: No SymSan executable was produced."
                        exit 1
                    fi

                    #
                    # Prefer a symbolic executable whose basename also
                    # exists in the AFL directory.
                    #
                    SYMSAN_TARGET=""

                    while IFS= read -r candidate; do
                        [ -z "\${candidate}" ] && continue

                        NAME="\$(basename "\${candidate}")"

                        if [ -f "\${AFL_OUT}/\${NAME}" ]; then
                            SYMSAN_TARGET="\${candidate}"
                            break
                        fi
                    done <<EOF
                    \${SYMSAN_TARGETS}
EOF

                    #
                    # If no matching basename exists, use the first
                    # executable. This is still recorded explicitly.
                    #
                    if [ -z "\${SYMSAN_TARGET}" ]; then
                        SYMSAN_TARGET="\$(printf '%s\\n' "\${SYMSAN_TARGETS}" | head -1)"
                    fi

                    SYMSAN_TARGET_NAME="\$(basename "\${SYMSAN_TARGET}")"

                    echo
                    echo "Selected SymSan target:"
                    echo "\${SYMSAN_TARGET}"

                    #
                    # Runtime environment.
                    #
                    cat > "\${SYMSAN_OUT}/symsan.env" <<EOF
AFL_CUSTOM_MUTATOR_LIBRARY=\\\$PWD/libSymSanMutator.so
SYMSAN_TARGET=\\\$PWD/\${SYMSAN_TARGET_NAME}
AFL_DISABLE_TRIM=1
EOF

                    #
                    # Human-readable metadata.
                    #
                    cat > "\${SYMSAN_OUT}/BUILD_INFO" <<EOF
PROJECT=${params.TARGET_PROJECT}
ARCHITECTURE=${params.TARGET_ARCH}
LLVM_VERSION=22
FUZZING_ENGINE=afl
SYMSAN_ENABLED=true
AFL_TARGET_DIRECTORY=../afl
SYMSAN_TARGET_DIRECTORY=.
SYMSAN_TARGET=\${SYMSAN_TARGET_NAME}
EOF

                    echo
                    echo "========================================"
                    echo "SymSan runtime bundle"
                    echo "========================================"

                    cat "\${SYMSAN_OUT}/symsan.env"
                    echo
                    cat "\${SYMSAN_OUT}/BUILD_INFO"
                """
            }
        }

        /*
         * ================================================================
         * VERIFY
         * ================================================================
         */
        stage('Verify Build') {
            steps {
                sh """
                    set -eux

                    PROJECT_OUT="oss-fuzz/build/out/${params.TARGET_PROJECT}"

                    echo "========================================"
                    echo "Build output"
                    echo "========================================"

                    find "\${PROJECT_OUT}" \
                        -maxdepth 3 \
                        -type f \
                        -print \
                        2>/dev/null || true

                    if [ "${params.ENABLE_SYMSAN}" = "true" ]; then

                        echo
                        echo "========================================"
                        echo "SymSan verification"
                        echo "========================================"

                        test -d "\${PROJECT_OUT}/afl"
                        test -d "\${PROJECT_OUT}/symsan"

                        test -f \
                            "\${PROJECT_OUT}/symsan/libSymSanMutator.so"

                        test -f \
                            "\${PROJECT_OUT}/symsan/symsan.env"

                        test -f \
                            "\${PROJECT_OUT}/symsan/BUILD_INFO"

                        echo
                        echo "AFL++ executables:"
                        find "\${PROJECT_OUT}/afl" \
                            -maxdepth 1 \
                            -type f \
                            -perm -111 \
                            -print \
                            2>/dev/null || true

                        echo
                        echo "SymSan executables:"
                        find "\${PROJECT_OUT}/symsan" \
                            -maxdepth 1 \
                            -type f \
                            -perm -111 \
                            ! -name 'libSymSanMutator.so' \
                            -print \
                            2>/dev/null || true

                        echo
                        echo "SymSan configuration:"
                        cat "\${PROJECT_OUT}/symsan/symsan.env"

                        echo
                        echo "SymSan build information:"
                        cat "\${PROJECT_OUT}/symsan/BUILD_INFO"

                    fi

                    echo
                    echo "========================================"
                    echo "Disk usage"
                    echo "========================================"

                    du -sh \
                        "\${PROJECT_OUT}"/* \
                        2>/dev/null || true
                """
            }
        }

        /*
         * ================================================================
         * UPLOAD
         * ================================================================
         */
        stage('Upload Build to Remote Server') {
            steps {
                sh """
                    set -eux

                    if [ "${params.ENABLE_SYMSAN}" = "true" ]; then
                        BUILD_MODE="symsan_aflpp_llvm22"
                    else
                        BUILD_MODE="${params.TARGET_ENGINE}_${params.TARGET_SANITIZER}"
                    fi

                    LOCAL_OUT="oss-fuzz/build/out/${params.TARGET_PROJECT}"

                    REMOTE_DIR="/home/ubuntu24/oss-fuzz/build/out/${params.TARGET_PROJECT}_\${BUILD_MODE}"

                    echo "Local output : \${LOCAL_OUT}"
                    echo "Remote output: \${REMOTE_DIR}"

                    sshpass -p '${REMOTE_PASS}' ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        ${REMOTE_USER}@${REMOTE_HOST} \
                        "mkdir -p '\${REMOTE_DIR}'"

                    #
                    # Remove stale files before upload so a previous build
                    # cannot leave obsolete binaries behind.
                    #
                    sshpass -p '${REMOTE_PASS}' ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        ${REMOTE_USER}@${REMOTE_HOST} \
                        "rm -rf '\${REMOTE_DIR:?}'/*"

                    sshpass -p '${REMOTE_PASS}' scp \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        -r \
                        "\${LOCAL_OUT}/"* \
                        ${REMOTE_USER}@${REMOTE_HOST}:"\${REMOTE_DIR}/"

                    echo
                    echo "========================================"
                    echo "Remote upload completed"
                    echo "========================================"

                    sshpass -p '${REMOTE_PASS}' ssh \
                        -o StrictHostKeyChecking=no \
                        -o UserKnownHostsFile=/dev/null \
                        ${REMOTE_USER}@${REMOTE_HOST} \
                        "find '\${REMOTE_DIR}' -maxdepth 3 -type f -print | sort"
                """
            }
        }
    }

    post {
        always {
            archiveArtifacts(
                artifacts: 'oss-fuzz/build/out/**/*',
                allowEmptyArchive: true
            )

            cleanWs()
        }
    }
}
