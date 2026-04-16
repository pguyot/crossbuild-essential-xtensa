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
    --interp-prefix=/usr/xtensa-lx6-linux-gnu \
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
mkdir -p "${PKG_DIR}/usr/lib/binfmt.d"

# Install the real binary as qemu-xtensa-esp32
cp "${QEMU_INSTALL_DIR}/bin/qemu-xtensa" "${PKG_DIR}/usr/local/bin/qemu-xtensa-esp32"

# Wrapper: defaults to esp32 CPU so callers (including binfmt) need no -cpu flag.
# Override by setting QEMU_XTENSA_CPU or passing -cpu explicitly; the wrapper
# checks whether -cpu already appears in the argument list and, if so, skips the
# default to avoid duplicate -cpu flags.
cat > "${PKG_DIR}/usr/local/bin/qemu-xtensa" << 'WRAPPER'
#!/bin/bash
cpu_set=false
for arg in "$@"; do
    [ "$arg" = "-cpu" ] && cpu_set=true && break
done
if ! $cpu_set; then
    exec /usr/local/bin/qemu-xtensa-esp32 -cpu "${QEMU_XTENSA_CPU:-esp32}" "$@"
fi
exec /usr/local/bin/qemu-xtensa-esp32 "$@"
WRAPPER
chmod 755 "${PKG_DIR}/usr/local/bin/qemu-xtensa"

# binfmt.d entry: kernel invokes /usr/local/bin/qemu-xtensa (the wrapper) for
# any 32-bit little-endian Xtensa ELF executable.  Activated automatically by
# systemd-binfmt on package install or on the next boot.
cat > "${PKG_DIR}/usr/lib/binfmt.d/qemu-xtensa-esp32.conf" << 'BINFMT'
:qemu-xtensa-esp32:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x5e\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/local/bin/qemu-xtensa:
BINFMT

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
 .
 Installs /usr/local/bin/qemu-xtensa (wrapper, defaults to -cpu esp32)
 and /usr/local/bin/qemu-xtensa-esp32 (real binary).
 .
 The wrapper uses /usr/xtensa-lx6-linux-gnu as the default library prefix,
 so cross-compiled binaries run without -L when the libc6-lx6 and other
 runtime packages are installed.  A binfmt.d entry is included so that
 cross-compiled Xtensa ELF binaries execute transparently.
EOF

cat > "${PKG_DIR}/DEBIAN/postinst" << 'POSTINST'
#!/bin/sh
set -e
# Activate the binfmt entry immediately if systemd-binfmt is available.
if [ -d /proc/sys/fs/binfmt_misc ] && command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-binfmt 2>/dev/null || true
fi
POSTINST
chmod 755 "${PKG_DIR}/DEBIAN/postinst"

cat > "${PKG_DIR}/DEBIAN/postrm" << 'POSTRM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    # Remove the binfmt entry from the kernel if it is loaded.
    if [ -f /proc/sys/fs/binfmt_misc/qemu-xtensa-esp32 ]; then
        echo -1 > /proc/sys/fs/binfmt_misc/qemu-xtensa-esp32 2>/dev/null || true
    fi
fi
POSTRM
chmod 755 "${PKG_DIR}/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "${PKG_DIR}" \
    "${BUILD_ROOT}/${PKG_NAME}_${QEMU_PKG_VERSION}_${PKG_ARCH}.deb"

log_info "Package: build/${PKG_NAME}_${QEMU_PKG_VERSION}_${PKG_ARCH}.deb"
