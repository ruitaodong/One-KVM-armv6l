#!/usr/bin/env bash
# Build One-KVM for ARMv6 (Raspberry Pi Zero / Zero W / Pi 1).
#
# No cross-compiling: a linux/arm/v6 container (Raspberry Pi OS armhf) runs
# directly on an arm64 host whose CPU executes 32-bit ARM code (Oracle Cloud
# Ampere A1, a Pi 4/400 with a 64-bit OS, GitHub arm64 runners) and builds
# One-KVM there with its own native gcc and rustc, as on a Pi. Check the host:
#   docker run --rm --platform linux/arm/v7 debian:trixie linux32 uname -m   -> armv8l
# Needs only Docker. The build environment is build/cross/Dockerfile.armv6.
#
# Usage: scripts/build-armv6.sh [build|image|shell]
#   build  (default) build the image if needed, compile, package the .deb
#   image  only build/update the reusable build environment onekvm-armv6:<suite>
#   shell  interactive shell in the build container, repo mounted at /src
#
#   SUITE=trixie|bookworm  Raspberry Pi OS release on the Pi (default trixie)
#   JOBS=N                 limit parallel compile jobs
#   CACHE=dir              Cargo downloads + build cache (default ~/.cache/onekvm-armv6/<suite>)
#   OUT_DIR=dir            where the .deb goes (default ./dist)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
MODE=${1:-build}

SUITE=${SUITE:-trixie}
case "$SUITE" in
    trixie)   TIME_BITS=64 ;;
    bookworm) TIME_BITS=32 ;;
    *) echo "SUITE must be trixie or bookworm" >&2; exit 1 ;;
esac
IMAGE=onekvm-armv6:$SUITE
PLATFORM=linux/arm/v6   # what the image is; it runs natively, no QEMU
OUT_DIR=${OUT_DIR:-$ROOT/dist}
CACHE=${CACHE:-$HOME/.cache/onekvm-armv6/$SUITE}
OWNER="$(id -u):$(id -g)"
mkdir -p "$OUT_DIR" "$CACHE/registry" "$CACHE/git" "$CACHE/target"
step() { printf '\n==> %s\n' "$*"; }

# The build environment: build/cross/Dockerfile.armv6 (Docker caches the layers)
toolchain_image() {
    step "Building build environment $IMAGE"
    docker build --platform "$PLATFORM" -f build/cross/Dockerfile.armv6 \
        --build-arg SUITE="$SUITE" --build-arg TIME_BITS="$TIME_BITS" -t "$IMAGE" build/cross
}

# Frontend (embedded into the binary from web/dist)
web() {
    step "Building web frontend"
    docker run --rm -v "$ROOT/web":/web -w /web node:24-bookworm-slim sh -euc "
        npm ci --no-audit --no-fund && npm run build
        chown -R $OWNER /web/dist /web/node_modules"
}

# docker run with the repo, caches and output mounted
in_container() {
    docker run --rm --platform "$PLATFORM" "$@" \
        -v "$ROOT":/src \
        -v "$CACHE/target":/src/target \
        -v "$CACHE/registry":/root/.cargo/registry \
        -v "$CACHE/git":/root/.cargo/git \
        -v "$OUT_DIR":/out \
        -e SUITE="$SUITE" -e OWNER="$OWNER" ${JOBS:+-e CARGO_BUILD_JOBS="$JOBS"} \
        "$IMAGE" bash -euo pipefail -c "$CMD"
}
FIX_OWNER='chown -R "$OWNER" /out /src/target /root/.cargo/registry /root/.cargo/git 2>/dev/null || true'

case "$MODE" in
image)
    toolchain_image
    step "Toolchain check"
    docker image inspect --format 'image platform: {{.Os}}/{{.Architecture}}/{{.Variant}}' "$IMAGE"
    docker run --rm --platform "$PLATFORM" "$IMAGE" bash -c '
        # a 64-bit kernel reports 32-bit processes as armv8l; the code is ARMv6
        echo "uname -m: $(uname -m)   gcc: $(gcc -dumpmachine)"
        gcc -Q --help=target | grep -E "^ +-m(arch|fpu|float-abi)=" | tr -s " "
        rustc -vV | grep -E "^(release|host)"'
    docker image ls onekvm-armv6
    ;;
shell)
    toolchain_image
    [ -f web/dist/index.html ] || web
    step "Shell in $IMAGE (repo at /src). Build with: cargo build --release"
    CMD="bash || true; $FIX_OWNER" in_container -it
    ;;
build)
    toolchain_image
    web
    step "Compiling and packaging"
    CMD='
        # Plain native build: rustc and gcc in this container are ARMv6 already
        cargo build --release
        BIN=target/release/one-kvm
        T=arm-unknown-linux-gnueabihf
        mkdir -p target/$T/release && cp "$BIN" target/$T/release/   # where package-deb.sh looks

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
        '"$FIX_OWNER" in_container
    step "Done"
    ls -la "$OUT_DIR"
    ;;
*)
    echo "usage: $0 [build|image|shell]" >&2; exit 1 ;;
esac
