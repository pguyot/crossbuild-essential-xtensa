#!/bin/bash
set -euo pipefail

# Common configuration for all build scripts
# VARIANT must be set before sourcing this file (lx6 or lx7)
# CHIP must be set before sourcing this file (esp32 or esp32s3)

export ARCH=xtensa
export TARGET=xtensa-${VARIANT}-linux-gnu
export JOBS=$(nproc)

# Toolchain is installed at /opt/xtensa-${VARIANT}/bin/ by crosstool-NG
export TOOLCHAIN_DIR=/opt/xtensa-${VARIANT}
export TOOLCHAIN_BIN=${TOOLCHAIN_DIR}/bin

# Ensure the cross-tools are found by CROSS_PREFIX-based lookups in configure scripts
export PATH="${TOOLCHAIN_BIN}:${PATH}"

export CC=${TARGET}-gcc
export CXX=${TARGET}-g++
export AR=${TARGET}-ar
export RANLIB=${TARGET}-ranlib
export STRIP=${TARGET}-strip

# CFLAGS for xtensa Linux userspace
# The windowed register ABI (call8) is default for xtensa-linux-gnu targets.
# No -march/-mabi flags needed: the toolchain was configured for the specific
# core variant (lx6/lx7) at build time via the xtensa overlay.
export CFLAGS="-O2 -fno-semantic-interposition -Wno-error"
export CXXFLAGS="-O2 -fno-semantic-interposition -Wno-error"
export LDFLAGS=""

# Installation prefix for cross-compilation packages on the host
export PREFIX=/usr/${TARGET}
export SYSROOT=${PREFIX}

# Package metadata
export MAINTAINER="Paul Guyot <pguyot@kallisys.net>"
export UBUNTU_VERSION="24.04"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Create directory structure
create_package_structure() {
    local package_name=$1
    local package_dir="build/${package_name}"

    mkdir -p "${package_dir}/DEBIAN"
    mkdir -p "${package_dir}${PREFIX}"

    echo "${package_dir}"
}

# Create .deb package
create_deb_package() {
    local package_dir=$1
    local package_name=$2
    local version=$3
    local description=$4
    local depends=$5

    cat > "${package_dir}/DEBIAN/control" << EOF
Package: ${package_name}
Version: ${version}
Section: libs
Priority: optional
Architecture: all
Maintainer: ${MAINTAINER}
Description: ${description}
${depends:+Depends: ${depends}}
EOF

    dpkg-deb --build "${package_dir}" "build/${package_name}_${version}_all.deb"
    log_info "Created package: build/${package_name}_${version}_all.deb"
}
