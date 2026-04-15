#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

GCC_VERSION=14.2.0
INSTALL_DIR="/opt/xtensa-${VARIANT}"
BUILD_DIR="$(pwd)/build/gcc-stage1-${VARIANT}"

log_info "Building GCC ${GCC_VERSION} stage 1 (bootstrap) for ${TARGET}"

# Get GCC source from Ubuntu (includes patches for cross-compilation)
if [ ! -d "gcc-${GCC_VERSION}" ]; then
    log_info "Getting GCC source from Ubuntu..."
    apt-get source gcc-14
    GCC_SRC_DIR=$(ls -d gcc-14-*/ 2>/dev/null | head -1 | sed 's:/$::')
    if [ -z "$GCC_SRC_DIR" ]; then
        log_error "Failed to extract GCC source"
        exit 1
    fi
    if [ "$GCC_SRC_DIR" != "gcc-${GCC_VERSION}" ]; then
        log_info "Renaming $GCC_SRC_DIR to gcc-${GCC_VERSION}"
        mv "$GCC_SRC_DIR" gcc-${GCC_VERSION}
    fi
    # Ubuntu package contains a nested tarball - extract if present
    cd gcc-${GCC_VERSION}
    if [ -f "gcc-${GCC_VERSION}.tar.xz" ]; then
        log_info "Extracting nested GCC tarball from Ubuntu package..."
        tar xf gcc-${GCC_VERSION}.tar.xz
        if [ -d "gcc-${GCC_VERSION}" ]; then
            mv gcc-${GCC_VERSION} src
        fi
    fi
    # Download prerequisites if needed (Ubuntu package may already include them)
    if [ -f "src/contrib/download_prerequisites" ]; then
        log_info "Downloading GCC prerequisites..."
        cd src && ./contrib/download_prerequisites && cd ..
    elif [ -f "contrib/download_prerequisites" ]; then
        log_info "Downloading GCC prerequisites..."
        ./contrib/download_prerequisites
    fi
    cd ..
fi

# Detect configure script location (Ubuntu package may nest source differently)
GCC_CONFIGURE=""
for possible_dir in "gcc-${GCC_VERSION}/src" "gcc-${GCC_VERSION}"; do
    if [ -f "${possible_dir}/configure" ]; then
        GCC_CONFIGURE="$(pwd)/${possible_dir}/configure"
        log_info "Found configure in ${possible_dir}"
        break
    fi
done
if [ -z "$GCC_CONFIGURE" ]; then
    log_error "Could not find GCC configure script"
    find "gcc-${GCC_VERSION}/" -name configure -type f 2>/dev/null || true
    exit 1
fi
GCC_SRC_ROOT="$(dirname "${GCC_CONFIGURE}")"

# Apply Espressif's xtensa overlay so GCC targets little-endian.
# The overlay's xtensa-config.h overrides XCHAL_HAVE_BE=1 (the upstream
# default) with XCHAL_HAVE_BE=0 and supplies the full ISA description for the
# specific core.  build-gcc-final.sh reuses the same source tree so the
# overlay only needs to be applied once here.
OVERLAYS_DIR="$(pwd)/xtensa-overlays"
if [ ! -d "${OVERLAYS_DIR}" ]; then
    log_info "Cloning espressif/xtensa-overlays..."
    git clone --depth=1 https://github.com/espressif/xtensa-overlays.git "${OVERLAYS_DIR}"
fi
OVERLAY_DIR="${OVERLAYS_DIR}/xtensa_${CHIP}/gcc"
if [ ! -d "${OVERLAY_DIR}" ]; then
    log_error "Overlay not found: ${OVERLAY_DIR}"
    log_error "Available overlays: $(ls "${OVERLAYS_DIR}/")"
    exit 1
fi
log_info "Applying xtensa_${CHIP} overlay to GCC (little-endian)..."
cp "${OVERLAY_DIR}/include/xtensa-config.h" "${GCC_SRC_ROOT}/gcc/config/xtensa/xtensa-config.h"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring GCC stage 1..."
unset CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS
"${GCC_CONFIGURE}" \
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
