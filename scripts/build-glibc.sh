#!/bin/bash
set -euo pipefail

VARIANT=$1  # lx6 or lx7
CHIP=$2     # esp32 or esp32s3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

log_info "Building glibc for ${TARGET} (${CHIP})"

# Upstream glibc does not support Xtensa; use jcmvbkbc's fork which adds
# full Xtensa support including windowed (call8) ABI.
GLIBC_VERSION=2.26
GLIBC_BRANCH="xtensa"
GLIBC_REPO="https://github.com/jcmvbkbc/glibc-xtensa.git"
GLIBC_SRC_DIR="glibc-xtensa-${GLIBC_VERSION}"
LIB_DIR="${TARGET}"
SYSROOT_DIR="/opt/xtensa-${VARIANT}/${TARGET}/sysroot"
REPO_ROOT="$(pwd)"          # capture before any cd
BUILD_DIR="${REPO_ROOT}/build/glibc-${VARIANT}"
PKG_VERSION="${GLIBC_VERSION}"

# ── Get glibc-xtensa source ───────────────────────────────────────────────────
if [ ! -d "${GLIBC_SRC_DIR}" ]; then
    log_info "Cloning jcmvbkbc/glibc-xtensa (branch ${GLIBC_BRANCH})..."
    git clone --branch "${GLIBC_BRANCH}" --depth 1 \
        "${GLIBC_REPO}" "${GLIBC_SRC_DIR}"
fi

# ── Verify stage 1 GCC is present ─────────────────────────────────────────────
STAGE1_GCC="${TOOLCHAIN_BIN}/${CC}"
if ! "${STAGE1_GCC}" --version >/dev/null 2>&1; then
    log_error "Stage 1 compiler not found: ${STAGE1_GCC}"
    log_error "Run build-gcc-stage1.sh first"
    exit 1
fi

# Kernel headers must already be installed in the sysroot
KERNEL_HEADERS="${SYSROOT_DIR}/usr/include"
if [ ! -d "${KERNEL_HEADERS}" ]; then
    log_error "Kernel headers not found at ${KERNEL_HEADERS}"
    log_error "Run build-linux-headers.sh first"
    exit 1
fi

# ── Build glibc ───────────────────────────────────────────────────────────────
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

log_info "Configuring glibc..."
"../../${GLIBC_SRC_DIR}/configure" \
    --prefix=/usr \
    --host="${TARGET}" \
    --build=x86_64-linux-gnu \
    --with-headers="${KERNEL_HEADERS}" \
    --enable-kernel=5.4.0 \
    --disable-werror \
    --disable-multilib \
    --disable-profile \
    --without-gd \
    --without-selinux \
    --disable-nscd \
    libc_cv_forced_unwind=yes \
    libc_cv_c_cleanup=yes \
    libc_cv_gcc_static_libgcc=-static-libgcc \
    libc_cv_alias_attribute_warning=no \
    CFLAGS="-O2 -Wno-error -std=gnu11" \
    CC="${STAGE1_GCC}" \
    || {
        log_error "glibc configure failed — config.log tail:"
        tail -100 config.log 2>/dev/null || true
        exit 1
    }

log_info "Building glibc (this takes a while)..."
make -j${JOBS} 2>&1 | tee build.log || {
    log_error "glibc build failed — last 80 lines of build.log:"
    tail -80 build.log
    exit 1
}

log_info "Installing glibc into sysroot ${SYSROOT_DIR}..."
mkdir -p "${SYSROOT_DIR}"
make install DESTDIR="${SYSROOT_DIR}" 2>&1 | tee -a build.log || {
    log_error "glibc install failed"
    tail -30 build.log
    exit 1
}

# Return to repo root before creating packages
cd "${REPO_ROOT}"

# ── Package: libc6-${VARIANT} (runtime) ───────────────────────────────────────
PKG_NAME="libc6-${VARIANT}"
log_info "Creating ${PKG_NAME} package..."
RUNTIME_DIR="${REPO_ROOT}/build/${PKG_NAME}"
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/DEBIAN"
mkdir -p "${RUNTIME_DIR}/usr/lib/${LIB_DIR}"

# Copy versioned shared libraries and dynamic loader
for src_dir in "${SYSROOT_DIR}/lib" "${SYSROOT_DIR}/usr/lib"; do
    [ -d "${src_dir}" ] || continue
    find "${src_dir}" -maxdepth 1 \
        \( -name "*.so.*" -o -name "ld-*.so*" -o -name "ld.so.*" \) \
        -exec cp -a {} "${RUNTIME_DIR}/usr/lib/${LIB_DIR}/" \; 2>/dev/null || true
done

# Sanity-check: libc.so.6 must be present
if ! ls "${RUNTIME_DIR}/usr/lib/${LIB_DIR}/libc.so"* >/dev/null 2>&1; then
    log_error "libc.so not found in sysroot — glibc install may have failed"
    log_error "Contents of ${SYSROOT_DIR}:"
    find "${SYSROOT_DIR}" -name "libc*" 2>/dev/null | head -20 || true
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
    "${REPO_ROOT}/build/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

# ── Package: libc6-dev-${VARIANT} (development) ───────────────────────────────
PKG_DEV="libc6-dev-${VARIANT}"
log_info "Creating ${PKG_DEV} package..."
DEV_DIR="${REPO_ROOT}/build/${PKG_DEV}"
rm -rf "${DEV_DIR}"
mkdir -p "${DEV_DIR}/DEBIAN"
mkdir -p "${DEV_DIR}/usr/lib/${LIB_DIR}"
mkdir -p "${DEV_DIR}/usr/include/${TARGET}"

# Headers (from sysroot — glibc + kernel headers merged by the install)
if [ -d "${SYSROOT_DIR}/usr/include" ]; then
    cp -a "${SYSROOT_DIR}/usr/include/." "${DEV_DIR}/usr/include/${TARGET}/"
fi

# Static libraries + unversioned symlinks (for -lc linking)
for src_dir in "${SYSROOT_DIR}/lib" "${SYSROOT_DIR}/usr/lib"; do
    [ -d "${src_dir}" ] || continue
    find "${src_dir}" -maxdepth 1 \( -name "*.a" -o -name "*.o" -o -name "*.so" \) \
        -exec cp -a {} "${DEV_DIR}/usr/lib/${LIB_DIR}/" \; 2>/dev/null || true
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
    "${REPO_ROOT}/build/${PKG_DEV}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_DEV}_${PKG_VERSION}_${ARCH}.deb"

# ── Package: libc6-dbg-${VARIANT} (debug) ─────────────────────────────────────
PKG_DBG="libc6-dbg-${VARIANT}"
log_info "Creating ${PKG_DBG} package..."
DBG_DIR="${REPO_ROOT}/build/${PKG_DBG}"
rm -rf "${DBG_DIR}"
mkdir -p "${DBG_DIR}/DEBIAN"
mkdir -p "${DBG_DIR}/usr/lib/${LIB_DIR}/debug"

for src_dir in "${SYSROOT_DIR}/lib" "${SYSROOT_DIR}/usr/lib"; do
    [ -d "${src_dir}" ] || continue
    find "${src_dir}" \( -name "*.so*" -o -name "*.a" \) | while read -r lib; do
        if file "${lib}" 2>/dev/null | grep -q "not stripped"; then
            subdir=$(dirname "${lib}" | sed "s|${src_dir}||")
            mkdir -p "${DBG_DIR}/usr/lib/${LIB_DIR}/debug/${subdir}"
            cp -a "${lib}" "${DBG_DIR}/usr/lib/${LIB_DIR}/debug/${subdir}/" 2>/dev/null || true
        fi
    done
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
 Detached debugging symbols for the GNU C Library for Xtensa ${VARIANT} (${CHIP}).
 .
 This package is for cross-compiling.
EOF

dpkg-deb --build --root-owner-group "${DBG_DIR}" \
    "${REPO_ROOT}/build/${PKG_DBG}_${PKG_VERSION}_${ARCH}.deb"
log_info "Created: ${PKG_DBG}_${PKG_VERSION}_${ARCH}.deb"

log_info "glibc build and packaging complete!"
