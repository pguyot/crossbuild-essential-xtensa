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

# Get binutils source from Ubuntu (includes patches for cross-compilation)
if [ ! -d "binutils-${BINUTILS_VERSION}" ]; then
    log_info "Getting binutils source from Ubuntu..."
    apt-get source binutils
    BINUTILS_SRC_DIR=$(ls -d binutils-*/ 2>/dev/null | head -1 | sed 's:/$::')
    if [ -z "$BINUTILS_SRC_DIR" ]; then
        log_error "Failed to extract binutils source"
        exit 1
    fi
    if [ "$BINUTILS_SRC_DIR" != "binutils-${BINUTILS_VERSION}" ]; then
        log_info "Renaming $BINUTILS_SRC_DIR to binutils-${BINUTILS_VERSION}"
        mv "$BINUTILS_SRC_DIR" binutils-${BINUTILS_VERSION}
    fi
fi

# Apply Espressif's xtensa overlay so gas assembles little-endian code.
# The overlay's xtensa-config.h overrides the big-endian defaults baked into
# binutils' include/xtensa-config.h.
OVERLAYS_DIR="$(pwd)/xtensa-overlays"
if [ ! -d "${OVERLAYS_DIR}" ]; then
    log_info "Cloning espressif/xtensa-overlays..."
    git clone --depth=1 https://github.com/espressif/xtensa-overlays.git "${OVERLAYS_DIR}"
fi
OVERLAY_DIR="${OVERLAYS_DIR}/xtensa_${CHIP}/binutils"
if [ ! -d "${OVERLAY_DIR}" ]; then
    log_error "Overlay not found: ${OVERLAY_DIR}"
    log_error "Available overlays: $(ls "${OVERLAYS_DIR}/")"
    exit 1
fi
log_info "Applying xtensa_${CHIP} overlay to binutils (little-endian)..."
cp "${OVERLAY_DIR}/include/xtensa-config.h" "binutils-${BINUTILS_VERSION}/include/xtensa-config.h"
cp "${OVERLAY_DIR}/bfd/xtensa-modules.c"    "binutils-${BINUTILS_VERSION}/bfd/xtensa-modules.c"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring binutils..."
unset CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS
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
