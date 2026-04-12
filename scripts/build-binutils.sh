#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BINUTILS_VERSION=2.42
INSTALL_DIR="/opt/xtensa-${VARIANT}"
BUILD_DIR="$(pwd)/build/binutils-${VARIANT}"

log_info "Building binutils ${BINUTILS_VERSION} for ${TARGET}"

# Download and extract if not already done
if [ ! -d "binutils-${BINUTILS_VERSION}" ]; then
    log_info "Downloading binutils ${BINUTILS_VERSION}..."
    wget -q --show-progress \
        "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"
    tar xf "binutils-${BINUTILS_VERSION}.tar.xz"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring binutils..."
../../binutils-${BINUTILS_VERSION}/configure \
    --target="${TARGET}" \
    --prefix="${INSTALL_DIR}" \
    --disable-nls \
    --disable-werror \
    --enable-gold \
    --enable-ld=default \
    --enable-plugins \
    --with-sysroot="${INSTALL_DIR}/${TARGET}/sysroot"

log_info "Building binutils..."
make -j${JOBS} 2>&1 | tee build.log || {
    log_error "binutils build failed — last 50 lines of build.log:"
    tail -50 build.log
    exit 1
}
sudo make install

log_info "binutils ${BINUTILS_VERSION} installed to ${INSTALL_DIR}"
