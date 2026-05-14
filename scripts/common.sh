#!/bin/bash
set -euo pipefail

# Common configuration for all build scripts
# VARIANT must be set before sourcing this file (lx6 or lx7)
# CHIP must be set before sourcing this file (esp32 or esp32s3)

export ARCH=xtensa
export TARGET=xtensa-${VARIANT}-linux-gnu
export JOBS=$(nproc)

# Toolchain is installed at /opt/xtensa-${VARIANT}/
export TOOLCHAIN_DIR=/opt/xtensa-${VARIANT}
export TOOLCHAIN_BIN=${TOOLCHAIN_DIR}/bin
export SYSROOT_DIR=${TOOLCHAIN_DIR}/${TARGET}/sysroot

# Prepend the cross-toolchain to PATH so cross-tools are found by
# configure scripts that rely on CROSS_PREFIX (e.g. zlib).
export PATH="${TOOLCHAIN_BIN}:${PATH}"

export CC=${TARGET}-gcc
export CXX=${TARGET}-g++
export AR=${TARGET}-ar
export RANLIB=${TARGET}-ranlib
export STRIP=${TARGET}-strip

# CFLAGS for xtensa Linux userspace.
# The windowed register ABI (call8) is the default for xtensa-linux-gnu.
# No -march/-mabi flags needed: the toolchain was configured for the
# specific core variant at build time.
export CFLAGS="-O2 -fno-semantic-interposition -Wno-error"
export CXXFLAGS="-O2 -fno-semantic-interposition -Wno-error"
export LDFLAGS=""

# Installation prefix for cross-compilation packages on the host
export PREFIX=/usr/${TARGET}

# Package metadata
export MAINTAINER="Paul Guyot <pguyot@kallisys.net>"

# ── Logging helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Ensure espressif/xtensa-overlays is checked out under $(pwd)/xtensa-overlays
# and verify the requested chip overlay exists.  Echoes the path to the chip
# overlay directory (e.g. xtensa-overlays/xtensa_esp32) on stdout; diagnostics
# go to stderr so callers can use "$(ensure_xtensa_overlay esp32)".
ensure_xtensa_overlay() {
    local chip="$1"
    local overlays_root="$(pwd)/xtensa-overlays"
    local overlay_dir="${overlays_root}/xtensa_${chip}"
    if [ ! -d "${overlays_root}" ]; then
        log_info "Fetching espressif/xtensa-overlays..." >&2
        git clone --depth=1 https://github.com/espressif/xtensa-overlays.git \
            "${overlays_root}" >&2
    fi
    if [ ! -d "${overlay_dir}" ]; then
        log_error "Overlay not found: ${overlay_dir}" >&2
        log_error "Available overlays: $(ls "${overlays_root}/")" >&2
        return 1
    fi
    echo "${overlay_dir}"
}
