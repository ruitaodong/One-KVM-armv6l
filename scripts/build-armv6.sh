#!/usr/bin/env bash
# Build One-KVM for ARMv6 (Raspberry Pi Zero / Zero W / Pi 1, Raspberry Pi OS 13 "trixie").
#
# No cross-compiling: a linux/arm/v6 Raspbian container runs directly on an
# arm64 host whose CPU executes 32-bit ARM code (GitHub's ubuntu-24.04-arm
# runners, Oracle Cloud Ampere A1, a Pi 4/400 with a 64-bit OS) and builds
# One-KVM there with its own native gcc and rustc, as on a Pi. Check the host:
#   docker run --rm --platform linux/arm/v6 tianon/raspbian:trixie-slim true && echo native
# with no QEMU handler for 32-bit ARM registered (/proc/sys/fs/binfmt_misc/qemu-arm
# absent or disabled), so that only the CPU can have run it.
# Other hosts (x86, Graviton 3+) work too once QEMU
# binfmt for arm is registered, e.g.
#   docker run --privileged --rm tonistiigi/binfmt --install arm
# but the build is several times slower.
# Needs only Docker. The build environment is build/cross/Dockerfile.armv6.
#
# Usage: scripts/build-armv6.sh [build|image|shell]
#   build  (default) build the image if needed, compile, package the .deb
#   image  only build/update the reusable build environment image
#   shell  interactive shell in the build container, repo mounted at /src
#
#   JOBS=N          limit parallel compile jobs
#   CACHE=dir       Cargo downloads + build cache (default ~/.cache/onekvm-armv6)
#   OUT_DIR=dir     where the .deb goes (default ./dist)
#   IMAGE=name:tag  build environment image name (default onekvm-armv6:latest)
#   CACHE_FROM=ref  registry image to reuse layers from, e.g.
#                   ghcr.io/ruitaodong/one-kvm-armv6-dev:latest
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
MODE=${1:-build}

IMAGE=${IMAGE:-onekvm-armv6:latest}
PLATFORM=linux/arm/v6
OUT_DIR=${OUT_DIR:-$ROOT/dist}
CACHE=${CACHE:-$HOME/.cache/onekvm-armv6}
OWNER="$(id -u):$(id -g)"
mkdir -p "$OUT_DIR" "$CACHE/registry" "$CACHE/git" "$CACHE/target"
step() { printf '\n==> %s\n' "$*"; }

# ARMv6 code issues memory barriers as CP15 instructions, which arm64
# kernels emulate by default (abi.cp15_barrier=1), making rustc several
# times slower; 2 lets the CPU execute them. Warn, don't change it.
if [ "$(uname -m)" = aarch64 ] && [ -r /proc/sys/abi/cp15_barrier ] \
   && [ "$(cat /proc/sys/abi/cp15_barrier)" != 2 ]; then
    echo "WARNING: abi.cp15_barrier=$(cat /proc/sys/abi/cp15_barrier): ARMv6 barriers are emulated" \
         "by the kernel and the build will be very slow. Fix: sudo sysctl -w abi.cp15_barrier=2" >&2
fi

# The build environment (Docker caches the layers). The image carries inline
# cache metadata, so a pulled copy (CACHE_FROM) is reused as layer cache.
toolchain_image() {
    step "Building build environment $IMAGE"
    docker build --platform "$PLATFORM" -f build/cross/Dockerfile.armv6 \
        --build-arg BUILDKIT_INLINE_CACHE=1 \
        --cache-from "$IMAGE" ${CACHE_FROM:+--cache-from "$CACHE_FROM"} \
        -t "$IMAGE" build/cross
}

# Frontend (embedded into the binary from web/dist)
web() {
    step "Building web frontend"
    docker run --rm -v "$ROOT/web":/web -w /web node:24-slim sh -euc "
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
        -e OWNER="$OWNER" ${JOBS:+-e CARGO_BUILD_JOBS="$JOBS"} \
        "$IMAGE" bash -euo pipefail -c "$CMD"
}
FIX_OWNER='chown -R "$OWNER" /out /src/target /root/.cargo/registry /root/.cargo/git 2>/dev/null || true'

case "$MODE" in
image)
    toolchain_image
    step "Toolchain check"
    docker run --rm --platform "$PLATFORM" "$IMAGE" bash -c '
        echo "uname -m: $(uname -m)   gcc: $(gcc -dumpmachine)"
        gcc -Q --help=target | grep -E "^ +-m(arch|fpu|float-abi)=" | tr -s " "
        rustc -vV | grep -E "^(release|host)"
        echo "libavcodec $(pkg-config --modversion libavcodec) (static, h264_v4l2m2m only)"'
    docker image ls "${IMAGE%%:*}"
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

        echo "Linked shared libraries:"; readelf -d "$BIN" | grep NEEDED
        # Depends: exactly the Raspbian packages providing those libraries
        D=$(mktemp -d); mkdir "$D/debian"
        printf "Source: one-kvm\n\nPackage: one-kvm\nArchitecture: armhf\n" > "$D/debian/control"
        DEPENDS=$(cd "$D" && dpkg-shlibdeps -O "/src/$BIN" | sed -n "s/^shlibs:Depends=//p")
        echo "Depends: $DEPENDS"

        OUTPUT_DIR=/out DEPENDS="$DEPENDS" DEB_NAME_SUFFIX=-armv6 \
            bash build/package-deb.sh $T
        cp "$BIN" /out/one-kvm-armv6
        '"$FIX_OWNER" in_container
    step "Done"
    ls -la "$OUT_DIR"
    ;;
*)
    echo "usage: $0 [build|image|shell]" >&2; exit 1 ;;
esac
