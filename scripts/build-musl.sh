#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

MUSL_VERSION=1.2.5
SYSROOT_DIR="/opt/xtensa-${VARIANT}/${TARGET}/sysroot"
REPO_ROOT="$(pwd)"
BUILD_DIR="${REPO_ROOT}/build/musl-${VARIANT}"

log_info "Building musl ${MUSL_VERSION} for ${TARGET} (${CHIP})"

# ── Download musl source ───────────────────────────────────────────────────────
if [ ! -d "musl-${MUSL_VERSION}" ]; then
    log_info "Downloading musl ${MUSL_VERSION}..."
    wget -q --show-progress \
        "https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz"
    tar xf "musl-${MUSL_VERSION}.tar.gz"
fi

# Verify musl has xtensa architecture support
if [ ! -d "musl-${MUSL_VERSION}/arch/xtensa" ]; then
    log_error "musl ${MUSL_VERSION} does not include xtensa architecture support."
    log_error "Available arches: $(ls musl-${MUSL_VERSION}/arch/ | tr '\n' ' ')"
    log_error "You need a musl version with xtensa patches (e.g. from musl-cross-make)."
    exit 1
fi

# ── Verify stage 1 GCC is present ─────────────────────────────────────────────
STAGE1_GCC="${TOOLCHAIN_BIN}/${CC}"
if ! "${STAGE1_GCC}" --version >/dev/null 2>&1; then
    log_error "Stage 1 compiler not found: ${STAGE1_GCC}"
    log_error "Run build-gcc-stage1.sh first"
    exit 1
fi

# Kernel headers must already be installed in the sysroot
if [ ! -d "${SYSROOT_DIR}/usr/include" ]; then
    log_error "Kernel headers not found at ${SYSROOT_DIR}/usr/include"
    log_error "Run build-linux-headers.sh first"
    exit 1
fi

# ── Build musl ────────────────────────────────────────────────────────────────
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring musl..."
# musl detects the target architecture from CC -dumpmachine.
# --syslibdir=/lib places ld-musl-xtensa.so.1 under /lib (the ELF interpreter path).
"../../musl-${MUSL_VERSION}/configure" \
    --prefix=/usr \
    --syslibdir=/lib \
    --disable-werror \
    CC="${STAGE1_GCC}" \
    CFLAGS="-O2"

log_info "Building musl..."
make -j${JOBS} 2>&1 | tee build.log || {
    log_error "musl build failed — last 50 lines of build.log:"
    tail -50 build.log
    exit 1
}

log_info "Installing musl into sysroot ${SYSROOT_DIR}..."
mkdir -p "${SYSROOT_DIR}"
make install DESTDIR="${SYSROOT_DIR}" 2>&1 | tee -a build.log || {
    log_error "musl install failed"
    tail -30 build.log
    exit 1
}

cd "${REPO_ROOT}"

# musl dynamic linker for little-endian xtensa
MUSL_LDSO="ld-musl-xtensa.so.1"

if [ ! -f "${SYSROOT_DIR}/lib/${MUSL_LDSO}" ]; then
    log_error "musl dynamic linker not found at ${SYSROOT_DIR}/lib/${MUSL_LDSO}"
    log_error "Contents of ${SYSROOT_DIR}/lib/:"
    ls "${SYSROOT_DIR}/lib/" 2>/dev/null | head -20 || true
    exit 1
fi

PKG_VERSION="${MUSL_VERSION}"

# ── Package: libmusl-${VARIANT} (runtime) ─────────────────────────────────────
PKG_NAME="libmusl-${VARIANT}"
log_info "Creating ${PKG_NAME} package..."
RUNTIME_DIR="${REPO_ROOT}/build/${PKG_NAME}"
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/DEBIAN"
mkdir -p "${RUNTIME_DIR}/lib"

# The dynamic linker is musl's shared libc itself
cp -a "${SYSROOT_DIR}/lib/${MUSL_LDSO}" "${RUNTIME_DIR}/lib/"

cat > "${RUNTIME_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Section: libs
Priority: optional
Maintainer: ${MAINTAINER}
Description: musl C Library: runtime (${ARCH} ${VARIANT} cross-compile)
 musl is a lightweight, fast, simple, free, and correct implementation of the
 C/POSIX standard library.  This package contains the musl dynamic linker
 for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling and qemu-user testing.
EOF

dpkg-deb --build --root-owner-group "${RUNTIME_DIR}" \
    "${REPO_ROOT}/build/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

# ── Package: libmusl-dev-${VARIANT} (development) ─────────────────────────────
PKG_DEV="libmusl-dev-${VARIANT}"
log_info "Creating ${PKG_DEV} package..."
DEV_DIR="${REPO_ROOT}/build/${PKG_DEV}"
rm -rf "${DEV_DIR}"
mkdir -p "${DEV_DIR}/DEBIAN"
mkdir -p "${DEV_DIR}/usr/lib/${TARGET}"
mkdir -p "${DEV_DIR}/usr/include/${TARGET}"

# Headers
if [ -d "${SYSROOT_DIR}/usr/include" ]; then
    cp -a "${SYSROOT_DIR}/usr/include/." "${DEV_DIR}/usr/include/${TARGET}/"
fi

# Static library, linker script (libc.so), and CRT objects (crt1.o, Scrt1.o, etc.)
find "${SYSROOT_DIR}/usr/lib" -maxdepth 1 \
    \( -name "*.a" -o -name "*.so" -o -name "*.o" \) \
    -exec cp -a {} "${DEV_DIR}/usr/lib/${TARGET}/" \; 2>/dev/null || true

cat > "${DEV_DIR}/DEBIAN/control" << EOF
Package: ${PKG_DEV}
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Section: libdevel
Priority: optional
Depends: ${PKG_NAME} (= ${PKG_VERSION})
Maintainer: ${MAINTAINER}
Description: musl C Library: development headers and libraries (${ARCH} ${VARIANT} cross-compile)
 Headers, static library, linker script, and CRT objects for cross-compiling
 against musl for Xtensa ${VARIANT} (${CHIP}).
 .
 Headers are installed at /usr/include/${TARGET}.
 Libraries are installed at /usr/lib/${TARGET}.
EOF

dpkg-deb --build --root-owner-group "${DEV_DIR}" \
    "${REPO_ROOT}/build/${PKG_DEV}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_DEV}_${PKG_VERSION}_${ARCH}.deb"

log_info "musl ${MUSL_VERSION} build and packaging complete!"
log_info "Dynamic linker: ${SYSROOT_DIR}/lib/${MUSL_LDSO}"
log_info "Test with: qemu-xtensa -L ${SYSROOT_DIR} <binary>"
