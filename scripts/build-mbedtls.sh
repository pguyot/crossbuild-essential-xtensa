#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_info "Building mbedtls for ${TARGET} (${CHIP})"

# Library directory for multiarch layout
LIB_DIR="${TARGET}"

MBEDTLS_VERSION=2.28.8
BUILD_DIR=$(pwd)/build/mbedtls-${VARIANT}
INSTALL_DIR=$(pwd)/build/mbedtls-install-${VARIANT}

# Get mbedtls source from Ubuntu
if [ ! -d "mbedtls-${MBEDTLS_VERSION}" ]; then
    log_info "Getting mbedtls source from Ubuntu..."
    apt-get source mbedtls
    MBEDTLS_SRC_DIR=$(ls -d mbedtls*/ 2>/dev/null | head -1 | sed 's:/$::')
    if [ -z "$MBEDTLS_SRC_DIR" ]; then
        log_error "Failed to extract mbedtls source"
        exit 1
    fi
    if [ "$MBEDTLS_SRC_DIR" != "mbedtls-${MBEDTLS_VERSION}" ] && [ ! -d "mbedtls-${MBEDTLS_VERSION}" ]; then
        log_info "Renaming $MBEDTLS_SRC_DIR to mbedtls-${MBEDTLS_VERSION}"
        mv "$MBEDTLS_SRC_DIR" mbedtls-${MBEDTLS_VERSION}
    fi
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring mbedtls..."
cmake "../../mbedtls-${MBEDTLS_VERSION}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_C_COMPILER="${TOOLCHAIN_BIN}/${CC}" \
    -DCMAKE_CXX_COMPILER="${TOOLCHAIN_BIN}/${CXX}" \
    -DCMAKE_C_FLAGS="${CFLAGS}" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=xtensa \
    -DENABLE_TESTING=OFF \
    -DENABLE_PROGRAMS=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=ON \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON

log_info "Building mbedtls..."
make -j${JOBS}

log_info "Installing mbedtls to staging directory..."
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
make install DESTDIR="${INSTALL_DIR}"

cd ../..

# ── libmbedcrypto (${VARIANT}) ─────────────────────────────────────────────────
PKG_CRYPTO="libmbedcrypto7-${VARIANT}"
log_info "Creating ${PKG_CRYPTO} package..."
CRYPTO_DIR=$(pwd)/build/${PKG_CRYPTO}
rm -rf "${CRYPTO_DIR}"
mkdir -p "${CRYPTO_DIR}/DEBIAN"
mkdir -p "${CRYPTO_DIR}/usr/${LIB_DIR}/lib"

cp -a "${INSTALL_DIR}${PREFIX}/lib/libmbedcrypto.so."* "${CRYPTO_DIR}/usr/${LIB_DIR}/lib/" 2>/dev/null || true

cat > "${CRYPTO_DIR}/DEBIAN/control" << EOF
Package: ${PKG_CRYPTO}
Architecture: ${ARCH}
Version: ${MBEDTLS_VERSION}-0ubuntu1
Multi-Arch: same
Section: libs
Priority: optional
Maintainer: ${MAINTAINER}
Description: lightweight crypto library - runtime (${ARCH} ${VARIANT} cross-compile)
 mbed TLS crypto library for cryptographic operations for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build "${CRYPTO_DIR}" \
    "build/${PKG_CRYPTO}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"
log_info "Created: ${PKG_CRYPTO}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"

# ── libmbedx509 (${VARIANT}) ───────────────────────────────────────────────────
PKG_X509="libmbedx509-1-${VARIANT}"
log_info "Creating ${PKG_X509} package..."
X509_DIR=$(pwd)/build/${PKG_X509}
rm -rf "${X509_DIR}"
mkdir -p "${X509_DIR}/DEBIAN"
mkdir -p "${X509_DIR}/usr/${LIB_DIR}/lib"

cp -a "${INSTALL_DIR}${PREFIX}/lib/libmbedx509.so."* "${X509_DIR}/usr/${LIB_DIR}/lib/" 2>/dev/null || true

cat > "${X509_DIR}/DEBIAN/control" << EOF
Package: ${PKG_X509}
Architecture: ${ARCH}
Version: ${MBEDTLS_VERSION}-0ubuntu1
Multi-Arch: same
Section: libs
Priority: optional
Depends: ${PKG_CRYPTO} (= ${MBEDTLS_VERSION}-0ubuntu1)
Maintainer: ${MAINTAINER}
Description: lightweight X.509 certificate library - runtime (${ARCH} ${VARIANT} cross-compile)
 mbed TLS X.509 certificate handling library for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build "${X509_DIR}" \
    "build/${PKG_X509}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"
log_info "Created: ${PKG_X509}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"

# ── libmbedtls (${VARIANT}) ────────────────────────────────────────────────────
PKG_TLS="libmbedtls14-${VARIANT}"
log_info "Creating ${PKG_TLS} package..."
TLS_DIR=$(pwd)/build/${PKG_TLS}
rm -rf "${TLS_DIR}"
mkdir -p "${TLS_DIR}/DEBIAN"
mkdir -p "${TLS_DIR}/usr/${LIB_DIR}/lib"

cp -a "${INSTALL_DIR}${PREFIX}/lib/libmbedtls.so."* "${TLS_DIR}/usr/${LIB_DIR}/lib/" 2>/dev/null || true

cat > "${TLS_DIR}/DEBIAN/control" << EOF
Package: ${PKG_TLS}
Architecture: ${ARCH}
Version: ${MBEDTLS_VERSION}-0ubuntu1
Multi-Arch: same
Section: libs
Priority: optional
Depends: ${PKG_CRYPTO} (= ${MBEDTLS_VERSION}-0ubuntu1), ${PKG_X509} (= ${MBEDTLS_VERSION}-0ubuntu1)
Maintainer: ${MAINTAINER}
Description: lightweight SSL/TLS library - runtime (${ARCH} ${VARIANT} cross-compile)
 mbed TLS TLS/SSL protocol implementation library for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build "${TLS_DIR}" \
    "build/${PKG_TLS}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"
log_info "Created: ${PKG_TLS}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"

# ── libmbedtls-dev (${VARIANT}) ────────────────────────────────────────────────
PKG_DEV="libmbedtls-dev-${VARIANT}"
log_info "Creating ${PKG_DEV} package..."
DEV_DIR=$(pwd)/build/${PKG_DEV}
rm -rf "${DEV_DIR}"
mkdir -p "${DEV_DIR}/DEBIAN"
mkdir -p "${DEV_DIR}/usr/${LIB_DIR}/lib"
mkdir -p "${DEV_DIR}/usr/${TARGET}/include"

cp -a "${INSTALL_DIR}${PREFIX}/include/." "${DEV_DIR}/usr/${TARGET}/include/" 2>/dev/null || true
cp -a "${INSTALL_DIR}${PREFIX}/lib/"*.a "${DEV_DIR}/usr/${LIB_DIR}/lib/" 2>/dev/null || true
# Unversioned symlinks needed for -lmbedtls etc.
for lib in libmbedcrypto libmbedx509 libmbedtls; do
    cp -a "${INSTALL_DIR}${PREFIX}/lib/${lib}.so" "${DEV_DIR}/usr/${LIB_DIR}/lib/" 2>/dev/null || true
done

cat > "${DEV_DIR}/DEBIAN/control" << EOF
Package: ${PKG_DEV}
Architecture: ${ARCH}
Version: ${MBEDTLS_VERSION}-0ubuntu1
Multi-Arch: same
Section: libdevel
Priority: optional
Depends: ${PKG_TLS} (= ${MBEDTLS_VERSION}-0ubuntu1), ${PKG_CRYPTO} (= ${MBEDTLS_VERSION}-0ubuntu1), ${PKG_X509} (= ${MBEDTLS_VERSION}-0ubuntu1), libc6-dev-${VARIANT}
Maintainer: ${MAINTAINER}
Description: lightweight crypto and SSL/TLS library - development (${ARCH} ${VARIANT} cross-compile)
 mbed TLS makes it easy for developers to include cryptographic and SSL/TLS
 capabilities in their embedded products.
 .
 This package contains the development files for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
 .
 Headers are installed at /usr/${TARGET}/include.
 Libraries are installed at /usr/${TARGET}/lib.
EOF

dpkg-deb --build "${DEV_DIR}" \
    "build/${PKG_DEV}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"
log_info "Created: ${PKG_DEV}_${MBEDTLS_VERSION}-0ubuntu1_${ARCH}.deb"

log_info "mbedtls build complete!"
