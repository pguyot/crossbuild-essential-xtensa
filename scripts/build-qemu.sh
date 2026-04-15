#!/bin/bash
set -euo pipefail

# Build qemu-xtensa (user-mode) from Espressif's QEMU fork.
# Produces build/qemu-xtensa-esp_<version>_amd64.deb, which installs
# /usr/local/bin/qemu-xtensa with ESP32 and ESP32-S3 CPU support.

QEMU_ESP_REPO="https://github.com/espressif/qemu.git"
QEMU_ESP_BRANCH="esp-develop"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/build"
QEMU_SRC_DIR="${REPO_ROOT}/qemu-esp"
QEMU_BUILD_DIR="${BUILD_ROOT}/qemu-build"
QEMU_INSTALL_DIR="${BUILD_ROOT}/qemu-install"

log_info()  { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

log_info "Installing QEMU build dependencies..."
sudo apt-get install -y \
    libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev \
    ninja-build python3

log_info "Cloning Espressif QEMU fork (branch ${QEMU_ESP_BRANCH})..."
if [ ! -d "${QEMU_SRC_DIR}" ]; then
    git clone --depth=1 --branch "${QEMU_ESP_BRANCH}" \
        "${QEMU_ESP_REPO}" "${QEMU_SRC_DIR}"
fi

QEMU_GIT_HASH="$(git -C "${QEMU_SRC_DIR}" rev-parse --short HEAD)"
QEMU_PKG_VERSION="0~esp-${QEMU_GIT_HASH}"
log_info "QEMU source hash: ${QEMU_GIT_HASH}"

rm -rf "${QEMU_BUILD_DIR}" "${QEMU_INSTALL_DIR}"
mkdir -p "${QEMU_BUILD_DIR}"
cd "${QEMU_BUILD_DIR}"

log_info "Configuring QEMU (xtensa-linux-user only)..."
"${QEMU_SRC_DIR}/configure" \
    --target-list=xtensa-linux-user \
    --prefix="${QEMU_INSTALL_DIR}" \
    --disable-docs \
    --disable-werror

log_info "Building QEMU..."
make -j"$(nproc)" 2>&1 | tee build.log || {
    log_error "QEMU build failed — last 50 lines:"
    tail -50 build.log
    exit 1
}
make install

cd "${REPO_ROOT}"

# Create DEB package
PKG_NAME="qemu-xtensa-esp"
PKG_ARCH="amd64"
PKG_DIR="${BUILD_ROOT}/${PKG_NAME}_${QEMU_PKG_VERSION}_${PKG_ARCH}"
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/local/bin"

cp "${QEMU_INSTALL_DIR}/bin/qemu-xtensa" "${PKG_DIR}/usr/local/bin/"

INSTALLED_SIZE=$(du -sk "${PKG_DIR}/usr" | cut -f1)

cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${QEMU_PKG_VERSION}
Architecture: ${PKG_ARCH}
Section: misc
Priority: optional
Installed-Size: ${INSTALLED_SIZE}
Maintainer: GitHub Actions <noreply@github.com>
Description: QEMU Xtensa user-mode emulator (Espressif fork)
 User-mode QEMU for Xtensa built from Espressif's fork, with full
 support for ESP32 (LX6) and ESP32-S3 (LX7) CPU models.
EOF

dpkg-deb --build --root-owner-group "${PKG_DIR}" \
    "${BUILD_ROOT}/${PKG_NAME}_${QEMU_PKG_VERSION}_${PKG_ARCH}.deb"

log_info "Package: build/${PKG_NAME}_${QEMU_PKG_VERSION}_${PKG_ARCH}.deb"
