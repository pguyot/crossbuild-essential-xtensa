#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_info "Extracting glibc for ${TARGET} from crosstool-NG sysroot"

# Locate the toolchain sysroot.
# crosstool-NG installs the sysroot at ${TOOLCHAIN_DIR}/${TARGET}/sysroot/
# We also try asking GCC directly.
if ${TOOLCHAIN_BIN}/${CC} --version >/dev/null 2>&1; then
    SYSROOT_PATH=$(${TOOLCHAIN_BIN}/${CC} -print-sysroot 2>/dev/null || true)
fi
if [ -z "${SYSROOT_PATH:-}" ] || [ ! -d "${SYSROOT_PATH}" ]; then
    SYSROOT_PATH="${TOOLCHAIN_DIR}/${TARGET}/sysroot"
fi
if [ ! -d "${SYSROOT_PATH}" ]; then
    log_error "Cannot find toolchain sysroot (tried ${TOOLCHAIN_DIR}/${TARGET}/sysroot)"
    log_error "Make sure the crosstool-NG toolchain is installed at ${TOOLCHAIN_DIR}"
    exit 1
fi
log_info "Sysroot: ${SYSROOT_PATH}"

# Detect glibc version from the installed libc.so.6 or version.h
GLIBC_VERSION="2.39"
VERSION_H="${SYSROOT_PATH}/usr/include/features.h"
if [ -f "${VERSION_H}" ]; then
    DETECTED=$(grep -oP '__GLIBC__\s+\K\d+' "${VERSION_H}" 2>/dev/null | head -1 || true)
    DETECTED_MINOR=$(grep -oP '__GLIBC_MINOR__\s+\K\d+' "${VERSION_H}" 2>/dev/null | head -1 || true)
    if [ -n "${DETECTED}" ] && [ -n "${DETECTED_MINOR}" ]; then
        GLIBC_VERSION="${DETECTED}.${DETECTED_MINOR}"
        log_info "Detected glibc version: ${GLIBC_VERSION}"
    fi
fi

PKG_VERSION="${GLIBC_VERSION}-0ubuntu1"

# Library directory for multiarch layout
LIB_DIR="${TARGET}"

# ── Runtime package (libc6-${VARIANT}) ────────────────────────────────────────
PKG_NAME="libc6-${VARIANT}"
log_info "Creating ${PKG_NAME} package..."
RUNTIME_DIR=$(pwd)/build/${PKG_NAME}
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/DEBIAN"
mkdir -p "${RUNTIME_DIR}/usr/lib/${LIB_DIR}"

# Copy versioned shared libraries from sysroot
# Typical locations in a ct-ng sysroot:
#   ${SYSROOT}/lib/              (dynamic loader)
#   ${SYSROOT}/usr/lib/          (libc.so.6, libm.so.6, etc.)
for src_dir in "${SYSROOT_PATH}/lib" "${SYSROOT_PATH}/usr/lib"; do
    if [ -d "${src_dir}" ]; then
        # *.so.*  — versioned shared libraries (libc.so.6, libm.so.6, …)
        # ld-*.so* — dynamic loaders (ld-linux.so.2, ld-xtensa.so.1, …)
        # ld.so.* — alternative dynamic loader naming
        find "${src_dir}" -maxdepth 1 \
            \( -name "*.so.*" -o -name "ld-*.so*" -o -name "ld.so.*" \) \
            -exec cp -a {} "${RUNTIME_DIR}/usr/lib/${LIB_DIR}/" \; 2>/dev/null || true
    fi
done

# Make sure we have at least libc.so.6
if ! ls "${RUNTIME_DIR}/usr/lib/${LIB_DIR}/libc.so"* >/dev/null 2>&1; then
    log_error "No libc.so found in sysroot - the toolchain sysroot may be incomplete"
    exit 1
fi

cat > "${RUNTIME_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Multi-Arch: same
Section: libs
Priority: optional
Maintainer: ${MAINTAINER}
Description: GNU C Library: Shared libraries (${ARCH} ${VARIANT} cross-compile)
 Contains the standard libraries that are used by nearly all programs on
 the system. This package includes shared versions of the standard C library
 and the standard math library, as well as many others for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build --root-owner-group "${RUNTIME_DIR}" \
    "build/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

# ── Development package (libc6-dev-${VARIANT}) ────────────────────────────────
PKG_DEV="libc6-dev-${VARIANT}"
log_info "Creating ${PKG_DEV} package..."
DEV_DIR=$(pwd)/build/${PKG_DEV}
rm -rf "${DEV_DIR}"
mkdir -p "${DEV_DIR}/DEBIAN"
mkdir -p "${DEV_DIR}/usr/lib/${LIB_DIR}"
mkdir -p "${DEV_DIR}/usr/include/${TARGET}"

# Copy headers
if [ -d "${SYSROOT_PATH}/usr/include" ]; then
    cp -a "${SYSROOT_PATH}/usr/include/." "${DEV_DIR}/usr/include/${TARGET}/" 2>/dev/null || true
fi

# Copy static libraries and unversioned .so symlinks (needed for -l linking)
for src_dir in "${SYSROOT_PATH}/lib" "${SYSROOT_PATH}/usr/lib"; do
    if [ -d "${src_dir}" ]; then
        find "${src_dir}" -maxdepth 1 \( -name "*.a" -o -name "*.o" \) \
            -exec cp -a {} "${DEV_DIR}/usr/lib/${LIB_DIR}/" \; 2>/dev/null || true
        # Unversioned .so symlinks for linking (e.g. libc.so -> libc.so.6)
        find "${src_dir}" -maxdepth 1 -name "*.so" \
            -exec cp -a {} "${DEV_DIR}/usr/lib/${LIB_DIR}/" \; 2>/dev/null || true
    fi
done

cat > "${DEV_DIR}/DEBIAN/control" << EOF
Package: ${PKG_DEV}
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Multi-Arch: same
Section: libdevel
Priority: optional
Depends: ${PKG_NAME} (= ${PKG_VERSION})
Maintainer: ${MAINTAINER}
Description: GNU C Library: Development Libraries and Headers (${ARCH} ${VARIANT} cross-compile)
 Contains the symlinks, headers, and object files needed to compile
 and link programs which use the standard C library for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
 .
 Headers are installed at /usr/include/${TARGET}.
EOF

dpkg-deb --build --root-owner-group "${DEV_DIR}" \
    "build/${PKG_DEV}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_DEV}_${PKG_VERSION}_${ARCH}.deb"

# ── Debug package (libc6-dbg-${VARIANT}) ──────────────────────────────────────
PKG_DBG="libc6-dbg-${VARIANT}"
log_info "Creating ${PKG_DBG} package..."
DBG_DIR=$(pwd)/build/${PKG_DBG}
rm -rf "${DBG_DIR}"
mkdir -p "${DBG_DIR}/DEBIAN"
mkdir -p "${DBG_DIR}/usr/lib/${LIB_DIR}/debug"

# Collect unstripped libraries from the sysroot (if any)
for src_dir in "${SYSROOT_PATH}/lib" "${SYSROOT_PATH}/usr/lib"; do
    if [ -d "${src_dir}" ]; then
        find "${src_dir}" -name "*.so*" -o -name "*.a" | while read -r lib; do
            if file "${lib}" | grep -q "not stripped"; then
                subdir=$(dirname "${lib}" | sed "s|${src_dir}||")
                mkdir -p "${DBG_DIR}/usr/lib/${LIB_DIR}/debug/${subdir}"
                cp -a "${lib}" "${DBG_DIR}/usr/lib/${LIB_DIR}/debug/${subdir}/" 2>/dev/null || true
            fi
        done
    fi
done

cat > "${DBG_DIR}/DEBIAN/control" << EOF
Package: ${PKG_DBG}
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Multi-Arch: same
Section: debug
Priority: optional
Depends: ${PKG_NAME} (= ${PKG_VERSION})
Maintainer: ${MAINTAINER}
Description: GNU C Library: detached debugging symbols (${ARCH} ${VARIANT} cross-compile)
 This package contains the detached debugging symbols for the GNU C Library
 for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build --root-owner-group "${DBG_DIR}" \
    "build/${PKG_DBG}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_DBG}_${PKG_VERSION}_${ARCH}.deb"

log_info "glibc extraction complete!"
