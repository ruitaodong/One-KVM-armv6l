# One-KVM for ARMv6 (Raspberry Pi Zero / Zero W / Pi 1)

Upstream's armhf packages are ARMv7 and crash on the Zero/Zero W with
`Illegal instruction`. This fork builds a real ARMv6 package the simple way:
**natively, inside a Raspberry Pi OS armhf container**. Raspberry Pi OS's
compiler already targets ARMv6, and FFmpeg, ALSA, udev etc. come from its own
packages. Only libjpeg-turbo 3 and libyuv are built from source.

It also passes UYVY frames from HDMI-CSI bridges (TC358743) straight to the
Pi's hardware H.264 encoder (`ONE_KVM_PI_UYVY_DIRECT=0` disables this).

**The build host** must be arm64 Linux whose CPU runs 32-bit ARM code:
Oracle Cloud Ampere A1, a Pi 4/400 on a 64-bit OS, or a GitHub arm64 runner
if its CPU supports it. Check (must print `armv8l`):

```sh
docker run --rm --platform linux/arm/v7 debian:trixie linux32 uname -m
```

(Apple Silicon and x86 machines can't run 32-bit ARM natively.)

**The package must match the Pi's Raspberry Pi OS release** (FFmpeg comes from
it): `SUITE=trixie` (13, default) or `SUITE=bookworm` (12). On the Pi:
`grep VERSION_CODENAME /etc/os-release`.

## Build

```sh
git clone https://github.com/ruitaodong/One-KVM-armv6l && cd One-KVM-armv6l
./scripts/build-armv6.sh          # SUITE=bookworm ./scripts/build-armv6.sh for 12
```

Result: `dist/one-kvm_<version>_armhf-armv6-<suite>.deb`. The first run creates
the Raspberry Pi OS base image (uses `sudo` for `mmdebstrap`); later runs reuse
it and the Rust build cache in `~/.cache/onekvm-armv6/`.

### GitHub Actions

Actions → **Build ARMv6 (Pi Zero / Zero W)** → Run workflow, pick the suite and
runner. The first step checks that the runner can run 32-bit ARM and stops
with a clear error if not. Download the `one-kvm-armv6-<suite>` artifact.

### Oracle Cloud (Always Free Ampere A1)

1. Create an instance: image *Canonical Ubuntu 24.04* (aarch64), shape
   *VM.Standard.A1.Flex*, 4 OCPU / 24 GB. ("Out of host capacity": try
   another availability domain or retry later.)
2. Set up and build:
   ```sh
   sudo apt update && sudo apt install -y docker.io git tmux
   sudo usermod -aG docker "$USER" && newgrp docker
   git clone https://github.com/ruitaodong/One-KVM-armv6l && cd One-KVM-armv6l
   tmux new -s build './scripts/build-armv6.sh 2>&1 | tee build.log'
   ```
3. Optional, as a GitHub runner: Settings → Actions → Runners → *New
   self-hosted runner* (Linux, ARM64), run the commands shown on the VM, then
   run the workflow with `runner: self-hosted`. Only on a repository whose
   workflows you control.

## Install on the Pi

```sh
sudo apt update
sudo apt install ./one-kvm_*_armhf-armv6-trixie.deb     # also pulls in FFmpeg libs
ldd /usr/bin/one-kvm | grep -E 'avcodec|not found'        # resolved, nothing "not found"
```

USB OTG: `dtoverlay=dwc2,dr_mode=peripheral` in `config.txt` and no other USB
gadget (`g_serial`, `g_ether`, ...) loaded. The Zero has one OTG port, and
One-KVM creates its own gadget.

## Notes

- Release builds use thin LTO: rustc runs as a 32-bit program here and
  One-KVM's full LTO may not fit in 4 GB.
- The build prints the binary's `Tag_CPU_arch`. Crypto libraries include NEON
  code that is only used when the CPU has NEON, which can label the binary
  v7/NEON; that's expected. Everything else is compiled by Raspberry Pi OS's
  ARMv6 compiler.
