#!/usr/bin/env bash
# Build One-KVM for ARMv6 (Raspberry Pi Zero / Zero W / Pi 1).
#
# Compiles natively inside a Raspberry Pi OS armhf container, so the host must
# be arm64 Linux whose CPU can run 32-bit ARM code: Oracle Cloud Ampere A1,
# a Pi 4/400 with a 64-bit OS, GitHub arm64 runners (if supported). Check:
#   docker run --rm --platform linux/arm/v7 debian:trixie linux32 uname -m   -> armv8l
# Needs Docker, and sudo once per suite (mmdebstrap creates the base image).
#
# Output: dist/one-kvm_<version>_armhf-armv6-<suite>.deb and the bare binary.
#
#   SUITE=trixie|bookworm  Raspberry Pi OS release on the Pi (default trixie)
#   JOBS=N                 limit parallel compile jobs
#   CACHE=dir              Cargo downloads + build cache (default ~/.cache/onekvm-armv6/<suite>)
#   OUT_DIR=dir            where the .deb goes (default ./dist)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

SUITE=${SUITE:-trixie}
case "$SUITE" in
    trixie)   TIME_BITS=64 ;;
    bookworm) TIME_BITS=32 ;;
    *) echo "SUITE must be trixie or bookworm" >&2; exit 1 ;;
esac
BASE=onekvm-raspbian:$SUITE
IMAGE=onekvm-armv6:$SUITE
OUT_DIR=${OUT_DIR:-$ROOT/dist}
CACHE=${CACHE:-$HOME/.cache/onekvm-armv6/$SUITE}
mkdir -p "$OUT_DIR" "$CACHE/registry" "$CACHE/git" "$CACHE/target"
step() { printf '\n==> %s\n' "$*"; }

# 1. Raspberry Pi OS armhf base image with all build dependencies (once per suite)
if ! docker image inspect "$BASE" >/dev/null 2>&1; then
    step "Creating Raspberry Pi OS ($SUITE, armhf) base image"
    command -v mmdebstrap >/dev/null || sudo apt-get install -y mmdebstrap
    # apt verifies as its unprivileged _apt user and only reads keyrings named
    # *.gpg/*.asc, so the key file needs that extension and must be world-readable
    KEY=$(mktemp --suffix=.gpg)
    curl -fsSL https://archive.raspbian.org/raspbian.public.key | gpg --dearmor > "$KEY"
    chmod 644 "$KEY"
    # Write to a file first: piping straight into docker import could leave a
    # broken image behind after a failure, which later runs would then reuse
    TAR=$(mktemp --suffix=.tar)
    sudo mmdebstrap --variant=apt --architectures=armhf --keyring="$KEY" \
        --include="build-essential pkg-config cmake git curl ca-certificates xz-utils util-linux \
                   clang libclang-dev libasound2-dev libudev-dev libv4l-dev libdrm-dev \
                   libavcodec-dev libavutil-dev libopus-dev zlib1g-dev" \
        "$SUITE" "$TAR" "deb http://raspbian.raspberrypi.com/raspbian $SUITE main"
    docker import "$TAR" "$BASE"
    sudo rm -f "$TAR" "$KEY"
fi

# 2. Frontend (embedded into the binary from web/dist)
step "Building web frontend"
docker run --rm -v "$ROOT/web":/web -w /web node:24-bookworm-slim sh -euc "
    npm ci --no-audit --no-fund && npm run build
    chown -R $(id -u):$(id -g) /web/dist /web/node_modules"

# 3. Rust + libjpeg-turbo + libyuv on top (cached by Docker after the first time)
step "Building toolchain image $IMAGE"
docker build -f build/cross/Dockerfile.armv6 \
    --build-arg BASE="$BASE" --build-arg TIME_BITS="$TIME_BITS" -t "$IMAGE" build/cross

# 4. Compile, check, package
step "Compiling and packaging"
docker run --rm \
    -v "$ROOT":/src \
    -v "$CACHE/target":/src/target \
    -v "$CACHE/registry":/root/.cargo/registry \
    -v "$CACHE/git":/root/.cargo/git \
    -v "$OUT_DIR":/out \
    -e SUITE="$SUITE" -e OWNER="$(id -u):$(id -g)" ${JOBS:+-e CARGO_BUILD_JOBS="$JOBS"} \
    "$IMAGE" bash -euo pipefail -c '
        T=arm-unknown-linux-gnueabihf
        cargo build --release --target $T
        BIN=target/$T/release/one-kvm

        # Informational: runtime-detected NEON code (e.g. in crypto libraries)
        # can mark the binary v7/NEON even though it never runs on a Pi Zero.
        readelf -A "$BIN" | grep -E "Tag_CPU_arch:|Tag_Advanced_SIMD_arch" || true

        # The FFmpeg libraries it links (libavcodecNN, libavutilNN) become Depends
        FF_DEPS=$(readelf -d "$BIN" \
            | sed -n "s/.*Shared library: \[lib\(avcodec\|avutil\)\.so\.\([0-9]*\)\].*/lib\1\2/p" \
            | paste -sd, - | sed "s/,/, /g")
        OUTPUT_DIR=/out EXTRA_DEPS="$FF_DEPS" DEB_NAME_SUFFIX="-armv6-$SUITE" \
            bash build/package-deb.sh $T
        cp "$BIN" "/out/one-kvm-armv6-$SUITE"

        # Hand everything back to the calling user
        chown -R "$OWNER" /out /src/target /root/.cargo/registry /root/.cargo/git'

step "Done"
ls -la "$OUT_DIR"
