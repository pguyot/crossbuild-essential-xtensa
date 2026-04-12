#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_info "Building zlib for ${TARGET} (${CHIP})"

# Library directory for multiarch layout
LIB_DIR="${TARGET}"

ZLIB_VERSION=1.3.1
BUILD_DIR=$(pwd)/build/zlib-${VARIANT}
INSTALL_DIR=$(pwd)/build/zlib-install-${VARIANT}

# Get zlib source from Ubuntu
if [ ! -d "zlib-${ZLIB_VERSION}" ]; then
    log_info "Getting zlib source from Ubuntu..."
    apt-get source zlib
    ZLIB_SRC_DIR=$(ls -d zlib*/ 2>/dev/null | head -1 | sed 's:/$::')
    if [ -z "$ZLIB_SRC_DIR" ]; then
        log_error "Failed to extract zlib source"
        exit 1
    fi
    if [ "$ZLIB_SRC_DIR" != "zlib-${ZLIB_VERSION}" ] && [ ! -d "zlib-${ZLIB_VERSION}" ]; then
        log_info "Renaming $ZLIB_SRC_DIR to zlib-${ZLIB_VERSION}"
        mv "$ZLIB_SRC_DIR" zlib-${ZLIB_VERSION}
    fi
fi

# Build zlib (out-of-tree)
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cp -a zlib-${ZLIB_VERSION}/. "${BUILD_DIR}/"
cd "${BUILD_DIR}"

log_info "Configuring zlib..."
CROSS_PREFIX="${TARGET}-" \
CC="${TOOLCHAIN_BIN}/${CC}" \
CFLAGS="${CFLAGS}" \
./configure --prefix=${PREFIX}

log_info "Building zlib..."
make -j${JOBS}

log_info "Installing zlib to staging directory..."
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
make install DESTDIR="${INSTALL_DIR}"

cd ../..

# ── Runtime package (zlib1g-${VARIANT}) ───────────────────────────────────────
PKG_RT="zlib1g-${VARIANT}"
log_info "Creating ${PKG_RT} package..."
RT_DIR=$(pwd)/build/${PKG_RT}
rm -rf "${RT_DIR}"
mkdir -p "${RT_DIR}/DEBIAN"
mkdir -p "${RT_DIR}/usr/lib/${LIB_DIR}"

cp -a "${INSTALL_DIR}${PREFIX}/lib/libz.so."* "${RT_DIR}/usr/lib/${LIB_DIR}/" 2>/dev/null || true

cat > "${RT_DIR}/DEBIAN/control" << EOF
Package: ${PKG_RT}
Architecture: ${ARCH}
Version: ${ZLIB_VERSION}-0ubuntu1
Multi-Arch: same
Section: libs
Priority: optional
Maintainer: ${MAINTAINER}
Description: compression library - runtime (${ARCH} ${VARIANT} cross-compile)
 zlib is a library implementing the deflate compression method found
 in gzip and PKZIP.  This package includes the shared library for
 Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build "${RT_DIR}" "build/${PKG_RT}_${ZLIB_VERSION}-0ubuntu1_${ARCH}.deb"
log_info "Created: ${PKG_RT}_${ZLIB_VERSION}-0ubuntu1_${ARCH}.deb"

# ── Development package (zlib1g-dev-${VARIANT}) ───────────────────────────────
PKG_DEV="zlib1g-dev-${VARIANT}"
log_info "Creating ${PKG_DEV} package..."
DEV_DIR=$(pwd)/build/${PKG_DEV}
rm -rf "${DEV_DIR}"
mkdir -p "${DEV_DIR}/DEBIAN"
mkdir -p "${DEV_DIR}/usr/lib/${LIB_DIR}"
mkdir -p "${DEV_DIR}/usr/include/${TARGET}"

cp -a "${INSTALL_DIR}${PREFIX}/include/"*.h "${DEV_DIR}/usr/include/${TARGET}/" 2>/dev/null || true
cp -a "${INSTALL_DIR}${PREFIX}/lib/libz.so"  "${DEV_DIR}/usr/lib/${LIB_DIR}/" 2>/dev/null || true
cp -a "${INSTALL_DIR}${PREFIX}/lib/"*.a       "${DEV_DIR}/usr/lib/${LIB_DIR}/" 2>/dev/null || true

mkdir -p "${DEV_DIR}/usr/lib/${LIB_DIR}/pkgconfig"
if [ -f "${INSTALL_DIR}${PREFIX}/lib/pkgconfig/zlib.pc" ]; then
    cp "${INSTALL_DIR}${PREFIX}/lib/pkgconfig/zlib.pc" \
       "${DEV_DIR}/usr/lib/${LIB_DIR}/pkgconfig/"
    sed -i "s|libdir=.*|libdir=/usr/lib/${LIB_DIR}|g" \
        "${DEV_DIR}/usr/lib/${LIB_DIR}/pkgconfig/zlib.pc"
    sed -i "s|includedir=.*|includedir=/usr/include/${TARGET}|g" \
        "${DEV_DIR}/usr/lib/${LIB_DIR}/pkgconfig/zlib.pc"
fi

cat > "${DEV_DIR}/DEBIAN/control" << EOF
Package: ${PKG_DEV}
Architecture: ${ARCH}
Version: ${ZLIB_VERSION}-0ubuntu1
Multi-Arch: same
Section: libdevel
Priority: optional
Provides: libz-dev
Depends: ${PKG_RT} (= ${ZLIB_VERSION}-0ubuntu1), libc6-dev-${VARIANT}
Maintainer: ${MAINTAINER}
Description: compression library - development (${ARCH} ${VARIANT} cross-compile)
 zlib is a library implementing the deflate compression method found
 in gzip and PKZIP.  This package includes the development support
 files for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
 .
 Headers are installed at /usr/include/${TARGET}.
EOF

dpkg-deb --build "${DEV_DIR}" "build/${PKG_DEV}_${ZLIB_VERSION}-0ubuntu1_${ARCH}.deb"
log_info "Created: ${PKG_DEV}_${ZLIB_VERSION}-0ubuntu1_${ARCH}.deb"

log_info "zlib build complete!"
