#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

KERNEL_VERSION=6.8
SYSROOT_DIR="/opt/xtensa-${VARIANT}/${TARGET}/sysroot"
PACKAGE_NAME="linux-libc-dev-xtensa-${VARIANT}-cross"

log_info "Installing Linux ${KERNEL_VERSION} headers for ${TARGET} into sysroot"

if [ ! -d "linux-${KERNEL_VERSION}" ]; then
    log_info "Downloading Linux ${KERNEL_VERSION}..."
    wget -q --show-progress \
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
    tar xf "linux-${KERNEL_VERSION}.tar.xz"
fi

# Install xtensa kernel headers into the sysroot
mkdir -p "${SYSROOT_DIR}/usr"
cd "linux-${KERNEL_VERSION}"
log_info "Running make ARCH=xtensa headers_install..."
make ARCH=xtensa headers_install INSTALL_HDR_PATH="${SYSROOT_DIR}/usr"

# Also create a Debian package for standalone installation
log_info "Creating ${PACKAGE_NAME} DEB package..."
PKG_DIR="$(pwd)/../build/${PACKAGE_NAME}"
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/include/${TARGET}"

# Copy headers to the multiarch path
cp -r "${SYSROOT_DIR}/usr/include/." "${PKG_DIR}/usr/include/${TARGET}/"

cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: ${PACKAGE_NAME}
Version: ${KERNEL_VERSION}.0-0ubuntu1
Section: devel
Priority: optional
Architecture: all
Maintainer: ${MAINTAINER}
Description: Linux Kernel Headers for ${TARGET} cross-compilation
 Provides headers from the Linux ${KERNEL_VERSION} kernel for xtensa ${VARIANT}.
 These headers are used by glibc and other low-level libraries.
 .
 This package is for cross-compiling to xtensa ${VARIANT} (${CHIP:-unknown}).
EOF

cd ..
dpkg-deb --build "${PKG_DIR}" \
    "build/${PACKAGE_NAME}_${KERNEL_VERSION}.0-0ubuntu1_all.deb"
log_info "Created: ${PACKAGE_NAME}_${KERNEL_VERSION}.0-0ubuntu1_all.deb"

log_info "Linux headers installed to ${SYSROOT_DIR}/usr/include"
