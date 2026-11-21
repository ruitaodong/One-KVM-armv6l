# One-KVM for ARMv6 (Raspberry Pi Zero / Zero W / Pi 1)

Upstream's armhf packages are ARMv7 and crash on the Zero/Zero W with
`Illegal instruction`. This fork builds a real ARMv6 package for
**Raspberry Pi OS 13 (trixie)** with **no cross-compiling**: a `linux/arm/v6`
Raspberry Pi OS container compiles One-KVM natively, exactly as on a Pi.

It is trimmed for one job: **hardware H.264 from a CSI capture bridge**.

- FFmpeg is built from source as a tiny static library with only the Pi's
  V4L2 M2M H.264 encoder (`h264_v4l2m2m`, bcm2835-codec). No VAAPI, VDPAU,
  DRM, x264, x265, VP8/VP9: the package doesn't pull in Raspbian's FFmpeg and
  its dependency tree. Other codecs simply fail One-KVM's encoder probe.
- UYVY frames from HDMI-CSI bridges (TC358743) go straight to the encoder,
  without color conversion (`ONE_KVM_PI_UYVY_DIRECT=0` disables this).
- `Depends:` is computed with `dpkg-shlibdeps` from what the binary actually
  links (libc, libstdc++, ALSA, Opus, udev).
- libjpeg-turbo 3 and libyuv are built from source and linked statically.

**The build host** is Linux with Docker. Fastest is an arm64 machine whose CPU
runs 32-bit ARM code (GitHub's `ubuntu-24.04-arm` runners, Oracle Cloud Ampere
A1, a Pi 4/400 on a 64-bit OS); check (prints `armv8l`):

```sh
docker run --rm --platform linux/arm/v7 debian:trixie linux32 uname -m
```

Anything else (x86, Graviton 3+, Apple Silicon VMs) works under
QEMU after `docker run --privileged --rm tonistiigi/binfmt --install arm`,
several times slower.

## Build

```sh
git clone https://github.com/ruitaodong/One-KVM-armv6l && cd One-KVM-armv6l
./scripts/build-armv6.sh
```

Result: `dist/one-kvm_<version>_armhf-armv6.deb`. The first run builds the
build environment image; later runs reuse it and the Rust build cache in
`~/.cache/onekvm-armv6/`.

### The build environment: one Dockerfile

`build/cross/Dockerfile.armv6` is a self-contained `linux/arm/v6` image:
Raspbian (`tianon/raspbian:trixie-slim`) + gcc/clang and the -dev packages +
Rust with an ARMv6 host toolchain + minimal static FFmpeg + libjpeg-turbo 3 +
libyuv. It can be used without the script:

```sh
docker build --platform linux/arm/v6 -t onekvm-armv6 -f build/cross/Dockerfile.armv6 build/cross
docker run --rm -it --platform linux/arm/v6 -v "$PWD":/src onekvm-armv6
# inside: cargo build --release   ->  target/release/one-kvm (ARMv6)
```

Or through the script, which adds caches, the frontend and packaging:

```sh
./scripts/build-armv6.sh image    # build/update the image and print a toolchain check
./scripts/build-armv6.sh          # build the .deb in it (default "build")
./scripts/build-armv6.sh shell    # shell in the container, repo at /src
```

In the shell, `cargo build --release` works directly; caches are shared with
`build`, and file ownership is handed back to you on exit. Rebuild the image
from scratch with `docker rmi onekvm-armv6`.

### GitHub Actions

`.github/workflows/build-armv6.yml` runs `scripts/build-armv6.sh`:

- **Push a tag** (`git tag v0.2.9-armv6 && git push origin v0.2.9-armv6`):
  attaches `one-kvm_<version>_armhf-armv6.deb`, the bare binary and
  `SHA256SUMS` to the release for that tag.
- **Actions → Build ARMv6 (Pi Zero / Zero W) → Run workflow**: pick the
  runner; fill in *release_tag* to publish, otherwise download the
  `one-kvm-armv6` artifact.

Each run also pushes the build environment image to GHCR as
`ghcr.io/ruitaodong/one-kvm-armv6-dev:latest` (plus `:<commit>` and, when
publishing a release, `:<tag>`). Locally you can reuse its layers:

```sh
CACHE_FROM=ghcr.io/ruitaodong/one-kvm-armv6-dev:latest ./scripts/build-armv6.sh
# or use it directly
docker run --rm -it --platform linux/arm/v6 -v "$PWD":/src ghcr.io/ruitaodong/one-kvm-armv6-dev
```

New GHCR packages are private; make it public under the package's settings
if others should pull it.

GitHub's `ubuntu-24.04-arm` runners (Neoverse N2) run 32-bit ARM code
natively, so the container needs no QEMU there. The workflow checks this
first and falls back to QEMU (much slower) on a runner that can't. The Cargo
cache is saved even if the build step times out, so a re-run continues.

### Oracle Cloud (Always Free Ampere A1)

1. Create an instance: image *Canonical Ubuntu 24.04* (aarch64), shape
   *VM.Standard.A1.Flex*, 4 OCPU / 24 GB. ("Out of host capacity": try
   another availability domain or retry later.)
2. Set up and build:
   ```sh
   sudo apt update && sudo apt install -y docker.io git tmux
   sudo usermod -aG docker "$USER" && newgrp docker
   git clone https://github.com/ruitaodong/One-KVM-armv6l && cd One-KVM-armv6l
   ./scripts/build-armv6.sh image       # once: build environment (~15-30 min)
   tmux new -s build './scripts/build-armv6.sh 2>&1 | tee build.log'
   ```
   Later builds reuse the images: `git pull && ./scripts/build-armv6.sh`.
3. Optional, as a GitHub runner: Settings → Actions → Runners → *New
   self-hosted runner* (Linux, ARM64), run the commands shown on the VM, then
   run the workflow with `runner: self-hosted`. Only on a repository whose
   workflows you control.

## Install on the Pi

```sh
sudo apt update
sudo apt install ./one-kvm_*_armhf-armv6.deb
ldd /usr/bin/one-kvm | grep 'not found'      # prints nothing
```

USB OTG: `dtoverlay=dwc2,dr_mode=peripheral` in `config.txt` and no other USB
gadget (`g_serial`, `g_ether`, ...) loaded. The Zero has one OTG port, and
One-KVM creates its own gadget.

## Notes

- Release builds use thin LTO: rustc runs as a 32-bit program here and
  One-KVM's full LTO may not fit in 4 GB.
- Crypto libraries include NEON code that is only used when the CPU has NEON,
  which can label the binary v7/NEON in `readelf -A`; that's expected.
  Everything else is compiled for ARMv6.
