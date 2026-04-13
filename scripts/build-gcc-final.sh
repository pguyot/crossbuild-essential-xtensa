#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

GCC_VERSION=14.2.0
INSTALL_DIR="/opt/xtensa-${VARIANT}"
SYSROOT_DIR="${INSTALL_DIR}/${TARGET}/sysroot"
BUILD_DIR="$(pwd)/build/gcc-final-${VARIANT}"

log_info "Building GCC ${GCC_VERSION} final (with sysroot) for ${TARGET}"

# GCC source should already be present from build-gcc-stage1.sh
if [ ! -d "gcc-${GCC_VERSION}" ]; then
    log_error "GCC source not found (gcc-${GCC_VERSION}/)."
    log_error "Run build-gcc-stage1.sh first — it fetches the GCC source."
    exit 1
fi

# Detect configure script location (Ubuntu package may nest source differently)
GCC_CONFIGURE=""
for possible_dir in "gcc-${GCC_VERSION}/src" "gcc-${GCC_VERSION}"; do
    if [ -f "${possible_dir}/configure" ]; then
        GCC_CONFIGURE="$(pwd)/${possible_dir}/configure"
        break
    fi
done
if [ -z "$GCC_CONFIGURE" ]; then
    log_error "Could not find GCC configure script"
    find "gcc-${GCC_VERSION}/" -name configure -type f 2>/dev/null || true
    exit 1
fi

# Verify musl is in the sysroot
if [ ! -f "${SYSROOT_DIR}/lib/ld-musl-xtensa.so.1" ]; then
    log_error "musl not found in sysroot ${SYSROOT_DIR}."
    log_error "Run build-musl.sh first."
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring GCC final..."
unset CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS
"${GCC_CONFIGURE}" \
    --target="${TARGET}" \
    --prefix="${INSTALL_DIR}" \
    --with-sysroot="${SYSROOT_DIR}" \
    --enable-languages=c,c++ \
    --enable-shared \
    --enable-threads=posix \
    --enable-__cxa_atexit \
    --disable-nls \
    --disable-werror \
    --disable-multilib \
    --with-gnu-as \
    --with-gnu-ld

log_info "Building GCC final (this takes 1-2 hours)..."
make -j${JOBS} 2>&1 | tee build.log || {
    log_error "GCC final build failed — last 100 lines of build.log:"
    tail -100 build.log
    exit 1
}
sudo make install

log_info "GCC final installed to ${INSTALL_DIR}"
log_info ""
log_info "Toolchain summary:"
"${INSTALL_DIR}/bin/${TARGET}-gcc" --version
log_info "Sysroot: $(${INSTALL_DIR}/bin/${TARGET}-gcc -print-sysroot)"
