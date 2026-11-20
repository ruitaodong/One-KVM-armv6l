#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/ruitaodong/One-KVM-armv6l.git"
REPO_REF="${REPO_REF:-main}"
SRC_DIR="${PWD}/One-KVM"
BASE_IMAGE="vascoguita/raspios:armhf-trixie"
BUILDER_IMAGE="one-kvm-builder:trixie-armv6"
DOCKERFILE="${PWD}/Dockerfile.trixie-armv6"
PKG_NAME="one-kvm"
PKG_ARCH="armhf"

# 1. Pull the pre-built 32-bit Raspberry Pi OS Trixie image
echo "==> [1/5] Pulling ${BASE_IMAGE} (linux/arm/v6)..."
docker pull --platform linux/arm/v6 "${BASE_IMAGE}"

# 2. Clone or update One-KVM source
echo "==> [2/5] Syncing ${REPO_URL} (${REPO_REF})..."
if [[ ! -d "${SRC_DIR}/.git" ]]; then
  git clone --branch "${REPO_REF}" --depth 1 "${REPO_URL}" "${SRC_DIR}"
else
  git -C "${SRC_DIR}" fetch --depth 1 origin "${REPO_REF}"
  git -C "${SRC_DIR}" checkout --force FETCH_HEAD
fi

PKG_VERSION="${PKG_VERSION:-$(awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}' "${SRC_DIR}/Cargo.toml")}"
OUTPUT_DEB="${PWD}/${PKG_NAME}_${PKG_VERSION}-pi0w_${PKG_ARCH}.deb"

# 3. Build web frontend natively on arm64 (pure static assets)
echo "==> [3/5] Building web frontend in native 64-bit Node container..."
docker run --rm \
  --volume "${SRC_DIR}/web:/web" \
  --workdir /web \
  node:22-slim \
  /bin/bash -euo pipefail -c "npm install && npm run build"

# 4. Build the 32-bit ARMv6 Rust builder image
echo "==> [4/5] Building ${BUILDER_IMAGE}..."
docker build \
  --platform linux/arm/v6 \
  --file "${DOCKERFILE}" \
  --tag "${BUILDER_IMAGE}" \
  "${PWD}"

# 5. Compile One-KVM for ARMv6 and package .deb
echo "==> [5/5] Compiling One-KVM (${PKG_VERSION}) for Pi Zero W and packaging .deb..."
docker run --rm \
  --platform linux/arm/v6 \
  --volume "${SRC_DIR}:/workspace" \
  --volume "${PWD}:/out" \
  --workdir /workspace \
  --env PKG_NAME="${PKG_NAME}" \
  --env PKG_VERSION="${PKG_VERSION}" \
  --env PKG_ARCH="${PKG_ARCH}" \
  --env OUTPUT_DEB="/out/$(basename "${OUTPUT_DEB}")" \
  "${BUILDER_IMAGE}" \
  /bin/bash -euo pipefail -c '
    echo "--- Container architecture: dpkg=$(dpkg --print-architecture), uname=$(uname -m) ---"

    cargo build --release --target arm-unknown-linux-gnueabihf

    BIN_PATH="target/arm-unknown-linux-gnueabihf/release/${PKG_NAME}"
    if [[ ! -f "${BIN_PATH}" ]]; then
      echo "ERROR: Expected binary not found at ${BIN_PATH}"
      ls -la target/arm-unknown-linux-gnueabihf/release/
      exit 1
    fi

    echo "--- Auditing ELF attributes for pure ARMv6 compatibility ---"
    readelf --arch-specific "${BIN_PATH}"
    if readelf --arch-specific "${BIN_PATH}" | grep --quiet "Tag_Advanced_SIMD_arch"; then
      echo "ERROR: NEON instructions detected in binary! Aborting."
      exit 1
    fi
    objdump --private-headers "${BIN_PATH}" | grep NEEDED

    echo "--- Staging Debian package ---"
    STAGE_DIR="/tmp/deb-stage"
    rm --recursive --force "${STAGE_DIR}"
    mkdir --parents \
      "${STAGE_DIR}/DEBIAN" \
      "${STAGE_DIR}/usr/bin" \
      "${STAGE_DIR}/lib/systemd/system" \
      "${STAGE_DIR}/etc/udev/rules.d" \
      "${STAGE_DIR}/var/lib/one-kvm"

    install --mode=0755 "${BIN_PATH}" "${STAGE_DIR}/usr/bin/${PKG_NAME}"

    cat << "EOF" > "${STAGE_DIR}/lib/systemd/system/one-kvm.service"
[Unit]
Description=One-KVM Rust IP-KVM Daemon
After=network-online.target systemd-modules-load.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/var/lib/one-kvm
ExecStart=/usr/bin/one-kvm
Restart=on-failure
RestartSec=3
SupplementaryGroups=video audio

[Install]
WantedBy=multi-user.target
EOF

    cat << "EOF" > "${STAGE_DIR}/etc/udev/rules.d/99-one-kvm.rules"
KERNEL=="hidg[0-9]*", SUBSYSTEM=="hidg", GROUP="video", MODE="0660"
SUBSYSTEM=="video4linux", GROUP="video", MODE="0660"
EOF

    # Auto-compute exact Raspbian Trixie runtime shared library dependencies
    SHLIB_DEPS="$(dpkg-shlibdeps --ignore-missing-info -O "${STAGE_DIR}/usr/bin/${PKG_NAME}" | sed "s/^shlibs:Depends=//")"

    cat << EOF > "${STAGE_DIR}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: utils
Priority: optional
Architecture: ${PKG_ARCH}
Depends: ${SHLIB_DEPS}
Maintainer: Local ARMv6 Build
Description: One-KVM Rust IP-KVM daemon built natively for Raspberry Pi Zero W (ARMv6 Trixie)
EOF

    cat << "EOF" > "${STAGE_DIR}/DEBIAN/postinst"
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  udevadm control --reload-rules || true
  udevadm trigger || true
  systemctl daemon-reload || true
fi
exit 0
EOF
    chmod 0755 "${STAGE_DIR}/DEBIAN/postinst"

    dpkg-deb --build --root-owner-group "${STAGE_DIR}" "${OUTPUT_DEB}"
  '

echo "==> Done! Package created: ${OUTPUT_DEB}"
dpkg-deb --info "${OUTPUT_DEB}"
