#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/ruitaodong/One-KVM-armv6l.git}"
REPO_REF="${REPO_REF:-main}"
SYSROOT="${SYSROOT:-/opt/raspbian-trixie-armhf}"
REBUILD_SYSROOT="${REBUILD_SYSROOT:-0}"
BUILD_DOCKER="${BUILD_DOCKER:-0}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ghcr.io/ruitaodong/one-kvm-armv6l}"
BASE_IMAGE="vascoguita/raspios:armhf-trixie"
CARGO_BUILD_TARGET="arm-unknown-linux-gnueabihf"
PKG_NAME="one-kvm"
PKG_ARCH="armhf"

TMP_DIRS=()
cleanup() {
  for dir in "${TMP_DIRS[@]}"; do
    rm --recursive --force "${dir}"
  done
}
trap cleanup EXIT

if [[ -f "${PWD}/Cargo.toml" && -d "${PWD}/web" ]]; then
  SRC_DIR="${PWD}"
  OUT_DIR="${PWD}"
else
  SRC_DIR="${PWD}/One-KVM"
  OUT_DIR="${PWD}"
fi

# 1. Install 64-bit host cross-compilation tools and native aarch64 Rust toolchain
echo "==> [1/7] Checking OCI A1 host cross-compilation tools..."
HOST_PKGS=(
  binutils-arm-linux-gnueabihf
  clang
  cmake
  dpkg-dev
  g++-arm-linux-gnueabihf
  gcc-arm-linux-gnueabihf
  libclang-dev
  pkg-config
  symlinks
)

MISSING_PKGS=()
for pkg in "${HOST_PKGS[@]}"; do
  if ! dpkg-query --show --showformat='${Status}' "${pkg}" 2>/dev/null | grep --quiet "install ok installed"; then
    MISSING_PKGS+=("${pkg}")
  fi
done

if (( ${#MISSING_PKGS[@]} > 0 )); then
  sudo apt-get update
  sudo apt-get install --yes --no-install-recommends "${MISSING_PKGS[@]}"
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo "==> Installing native 64-bit aarch64 Rust toolchain..."
  curl --proto '=https' --tlsv1.2 --silent --show-error --fail https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
fi

export PATH="${HOME}/.cargo/bin:${PATH}"
rustup target add "${CARGO_BUILD_TARGET}"

# 2. Sync source repository if not running inside an existing checkout
if [[ "${SRC_DIR}" != "${PWD}" ]]; then
  echo "==> [2/7] Syncing ${REPO_URL} (${REPO_REF})..."
  if [[ ! -d "${SRC_DIR}/.git" ]]; then
    git clone --branch "${REPO_REF}" --depth 1 "${REPO_URL}" "${SRC_DIR}"
  else
    git -C "${SRC_DIR}" fetch --depth 1 origin "${REPO_REF}"
    git -C "${SRC_DIR}" checkout --force FETCH_HEAD
  fi
else
  echo "==> [2/7] Using existing checkout at ${SRC_DIR}."
fi

# 3. Export Raspbian Trixie ARMv6 sysroot (cached on disk after first run)
if [[ "${REBUILD_SYSROOT}" == "1" || ! -f "${SYSROOT}/usr/include/libyuv.h" ]]; then
  echo "==> [3/7] Building and exporting Raspbian Trixie ARMv6 sysroot to ${SYSROOT}..."
  SYSROOT_DOCKERFILE="${SRC_DIR}/Dockerfile.sysroot"
  if [[ ! -f "${SYSROOT_DOCKERFILE}" ]]; then
    echo "ERROR: ${SYSROOT_DOCKERFILE} not found."
    exit 1
  fi

  docker pull --platform linux/arm/v6 "${BASE_IMAGE}"
  docker build \
    --platform linux/arm/v6 \
    --file "${SYSROOT_DOCKERFILE}" \
    --tag raspbian-trixie-sysroot:armhf \
    "${SRC_DIR}"

  CONTAINER_ID="$(docker create --platform linux/arm/v6 raspbian-trixie-sysroot:armhf)"
  sudo rm --recursive --force "${SYSROOT}"
  sudo mkdir --parents "${SYSROOT}"
  docker export "${CONTAINER_ID}" | sudo tar --extract --directory="${SYSROOT}"
  docker rm "${CONTAINER_ID}" >/dev/null

  sudo symlinks -cr "${SYSROOT}"
  for lib in "${SYSROOT}"/usr/lib/arm-linux-gnueabihf/libyuv.*; do
    sudo ln --symbolic --force "arm-linux-gnueabihf/$(basename "${lib}")" "${SYSROOT}/usr/lib/$(basename "${lib}")"
  done
  sudo chown --recursive "$(id --user):$(id --group)" "${SYSROOT}"
else
  echo "==> [3/7] Using cached Raspbian Trixie ARMv6 sysroot at ${SYSROOT}."
fi

PKG_VERSION="${PKG_VERSION:-$(awk -F'"' '/^version[[:space:]]*=/ {print $2; exit}' "${SRC_DIR}/Cargo.toml")}"
if [[ "${PKG_VERSION}" == *-pi0w ]]; then
  DOCKER_TAG="${DOCKER_TAG:-${PKG_VERSION}}"
  OUTPUT_DEB="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"
else
  DOCKER_TAG="${DOCKER_TAG:-${PKG_VERSION}-pi0w}"
  OUTPUT_DEB="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}-pi0w_${PKG_ARCH}.deb"
fi

# 4. Build web frontend natively on arm64
echo "==> [4/7] Building web frontend in native 64-bit Node container..."
docker run --rm \
  --user "$(id --user):$(id --group)" \
  --env npm_config_cache=/tmp/.npm \
  --volume "${SRC_DIR}/web:/web" \
  --workdir /web \
  node:22-slim \
  /bin/bash -euo pipefail -c "npm install && npm run build"

# 5. Cross-compile One-KVM natively with 64-bit aarch64 rustc
echo "==> [5/7] Cross-compiling One-KVM (${PKG_VERSION}) natively on $(uname --machine) for Pi Zero W..."
(
  cd "${SRC_DIR}"
  export CARGO_TARGET_ARM_UNKNOWN_LINUX_GNUEABIHF_LINKER="arm-linux-gnueabihf-gcc"
  export CARGO_TARGET_ARM_UNKNOWN_LINUX_GNUEABIHF_RUSTFLAGS="-C target-cpu=arm1176jzf-s -C target-feature=+vfp2,-neon,-v7 -C link-arg=--sysroot=${SYSROOT} -C link-arg=-Wl,-rpath-link=${SYSROOT}/usr/lib/arm-linux-gnueabihf -C link-arg=-Wl,-rpath-link=${SYSROOT}/lib/arm-linux-gnueabihf"
  export CC_arm_unknown_linux_gnueabihf="arm-linux-gnueabihf-gcc"
  export CXX_arm_unknown_linux_gnueabihf="arm-linux-gnueabihf-g++"
  export AR_arm_unknown_linux_gnueabihf="arm-linux-gnueabihf-ar"
  export CFLAGS_arm_unknown_linux_gnueabihf="-march=armv6zk -mtune=arm1176jzf-s -mfpu=vfp -mfloat-abi=hard --sysroot=${SYSROOT}"
  export CXXFLAGS_arm_unknown_linux_gnueabihf="${CFLAGS_arm_unknown_linux_gnueabihf}"
  export PKG_CONFIG_ALLOW_CROSS="1"
  export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
  export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/arm-linux-gnueabihf/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
  export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=${SYSROOT} --target=arm-unknown-linux-gnueabihf -I${SYSROOT}/usr/include/arm-linux-gnueabihf"
  export ONE_KVM_LIBS_PATH="${SYSROOT}/usr"
  export LIBYUV_STATIC="0"
  export FFMPEG_STATIC="0"

  cargo build --release --target "${CARGO_BUILD_TARGET}"
)

BIN_PATH="${SRC_DIR}/target/${CARGO_BUILD_TARGET}/release/${PKG_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "ERROR: Expected binary not found at ${BIN_PATH}"
  exit 1
fi

echo "--- Auditing ELF attributes for pure ARMv6 compatibility ---"
arm-linux-gnueabihf-readelf --arch-specific "${BIN_PATH}"
if arm-linux-gnueabihf-readelf --arch-specific "${BIN_PATH}" | grep --quiet "Tag_Advanced_SIMD_arch"; then
  echo "ERROR: NEON instructions detected in binary! Aborting."
  exit 1
fi
arm-linux-gnueabihf-objdump --private-headers "${BIN_PATH}" | grep NEEDED

# 6. Package .deb for Raspberry Pi OS Trixie (armhf)
echo "==> [6/7] Packaging ${OUTPUT_DEB}..."
STAGE_DIR="$(mktemp --directory /tmp/one-kvm-deb.XXXXXX)"
TMP_DIRS+=("${STAGE_DIR}")

mkdir --parents \
  "${STAGE_DIR}/DEBIAN" \
  "${STAGE_DIR}/usr/bin" \
  "${STAGE_DIR}/lib/systemd/system" \
  "${STAGE_DIR}/etc/udev/rules.d" \
  "${STAGE_DIR}/var/lib/one-kvm"

install --mode=0755 "${BIN_PATH}" "${STAGE_DIR}/usr/bin/${PKG_NAME}"

cat << 'EOF' > "${STAGE_DIR}/lib/systemd/system/one-kvm.service"
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

cat << 'EOF' > "${STAGE_DIR}/etc/udev/rules.d/99-one-kvm.rules"
KERNEL=="hidg[0-9]*", SUBSYSTEM=="hidg", GROUP="video", MODE="0660"
SUBSYSTEM=="video4linux", GROUP="video", MODE="0660"
EOF

cat << EOF > "${STAGE_DIR}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: utils
Priority: optional
Architecture: ${PKG_ARCH}
Depends: libc6, libssl3t64 | libssl3, libv4l-0t64 | libv4l-0, libasound2t64 | libasound2, libopus0, libturbojpeg0, libyuv0, libavcodec61 | libavcodec60, libavformat61 | libavformat60, libavutil59 | libavutil58, libswscale8 | libswscale7, libswresample5 | libswresample4
Maintainer: Rui-Tao Dong
Description: One-KVM Rust IP-KVM daemon built for Raspberry Pi Zero W (ARMv6 Trixie)
EOF

cat << 'EOF' > "${STAGE_DIR}/DEBIAN/postinst"
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
(
  cd "${OUT_DIR}"
  sha256sum "$(basename "${OUTPUT_DEB}")" > "${OUTPUT_DEB}.sha256"
)

echo "==> Package created: ${OUTPUT_DEB}"
dpkg-deb --info "${OUTPUT_DEB}"

# 7. Optional: Build minimal linux/arm/v6 runtime Docker image from the .deb
if [[ "${BUILD_DOCKER}" == "1" ]]; then
  echo "==> [7/7] Building minimal linux/arm/v6 runtime image (${DOCKER_IMAGE}:${DOCKER_TAG})..."
  RUNTIME_CTX="$(mktemp --directory /tmp/one-kvm-runtime.XXXXXX)"
  TMP_DIRS+=("${RUNTIME_CTX}")

  cp "${OUTPUT_DEB}" "${RUNTIME_CTX}/one-kvm.deb"

  cat << EOF > "${RUNTIME_CTX}/Dockerfile"
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive
COPY one-kvm.deb /tmp/one-kvm.deb
RUN apt-get update \
    && apt-get install --yes --no-install-recommends /tmp/one-kvm.deb \
    && apt-get clean \
    && rm --recursive --force /var/lib/apt/lists/* /tmp/one-kvm.deb /var/cache/apt/archives/*.deb
WORKDIR /var/lib/one-kvm
ENTRYPOINT ["/usr/bin/one-kvm"]
EOF

  docker build \
    --platform linux/arm/v6 \
    --file "${RUNTIME_CTX}/Dockerfile" \
    --tag "${DOCKER_IMAGE}:${DOCKER_TAG}" \
    "${RUNTIME_CTX}"

  docker image inspect "${DOCKER_IMAGE}:${DOCKER_TAG}" \
    --format 'Image built: {{index .RepoTags 0}} ({{.Architecture}}/{{.Variant}}, {{.Size}} bytes)'
else
  echo "==> [7/7] Skipping Docker runtime image build (set BUILD_DOCKER=1 to enable)."
fi