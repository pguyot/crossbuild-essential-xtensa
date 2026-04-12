#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

GCC_VERSION=13.2.0
INSTALL_DIR="/opt/xtensa-${VARIANT}"
BUILD_DIR="$(pwd)/build/gcc-stage1-${VARIANT}"

log_info "Building GCC ${GCC_VERSION} stage 1 (bootstrap) for ${TARGET}"

# Download and extract GCC if not already done
if [ ! -d "gcc-${GCC_VERSION}" ]; then
    log_info "Downloading GCC ${GCC_VERSION}..."
    wget -q --show-progress \
        "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"
    tar xf "gcc-${GCC_VERSION}.tar.xz"

    log_info "Downloading GCC prerequisites..."
    cd "gcc-${GCC_VERSION}"
    ./contrib/download_prerequisites
    cd ..
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring GCC stage 1..."
../../gcc-${GCC_VERSION}/configure \
    --target="${TARGET}" \
    --prefix="${INSTALL_DIR}" \
    --without-headers \
    --with-newlib \
    --enable-languages=c \
    --disable-shared \
    --disable-threads \
    --disable-nls \
    --disable-werror \
    --disable-multilib \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libgomp \
    --disable-libatomic \
    --disable-decimal-float \
    --with-gnu-as \
    --with-gnu-ld

log_info "Building GCC stage 1..."
make all-gcc all-target-libgcc -j${JOBS} 2>&1 | tee build.log || {
    log_error "GCC stage 1 build failed — last 80 lines of build.log:"
    tail -80 build.log
    exit 1
}
sudo make install-gcc install-target-libgcc

log_info "GCC stage 1 installed to ${INSTALL_DIR}"
log_info "Compiler: ${INSTALL_DIR}/bin/${TARGET}-gcc"
