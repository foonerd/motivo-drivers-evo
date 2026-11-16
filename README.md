# motivo-drivers-evo

Custom kernel modules and device tree overlays for
[Volumio Motivo](https://volumio.com/motivo/) hardware.

Builds against Raspberry Pi kernel sources for the CM4 (BCM2711) platform,
producing drop-in modules and overlays for Volumio OS.

## What this repo contains

| Component | Description |
|---|---|
| panel-dsi-mt.c | DRM panel driver for Motivo ILI9881-based 8" MIPI DSI displays |
| motivo-panel-a-overlay.dts | Device tree overlay for Panel A (Goodix GT9271 touch) |
| motivo-panel-b-overlay.dts | Device tree overlay for Panel B (Goodix GT911 touch) |
| es9039q2m-i2s-overlay.dts | Device tree overlay for ES9039Q2M DAC over I2S |
| quirks.c | USB audio DSD quirk flags for audiophile DAC hardware |
| endpoint.c, stream.c | USB audio, 6.12.115 set: interface setup order for Teac and Esoteric DACs, S32_LE in place of S24_3LE on dwc2 hosts |

## Build output

The build produces a tarball containing:

- panel-dsi-mt.ko.xz (32-bit and 64-bit)
- snd-usb-audio.ko.xz (32-bit and 64-bit)
- motivo-panel-a.dtbo
- motivo-panel-b.dtbo
- es9039q2m-i2s.dtbo

## Prerequisites

Ubuntu 22.04 or 24.04 build host with cross-compilation toolchains:

```
./build-script/install_deps.sh
```

## Building

Edit `KERNEL_VERSION` and `KERNEL_COMMIT` in `build-script/download_build.sh`,
then run:

```
cd build-script
./download_build.sh
```

The archive appears in `output/`.

To rebuild after editing source files:

```
cd build-script
./re-build.sh
```

### Kernel 6.12.115

Raspberry Pi publishes 6.12.115 only as Raspberry Pi OS packages, with the
kernel releases `6.12.115+rpt-rpi-v7l` and `6.12.115+rpt-rpi-v8`. It has no
rpi-firmware commit, so it has its own script:

```
cd build-script
./build_rpt.sh
```

This needs docker, and qemu-user-static registered with binfmt, in place of
the cross-compilation toolchains. The modules are built against the shipped
kernel: its configuration and symbol versions are taken from its headers
packages, and each flavour is compiled in a container of the distribution
and compiler that built it. Running the script again rebuilds after an edit
to the source files.

## How it works

The build script downloads the specified Raspberry Pi kernel source,
injects Motivo source files and build system entries, then cross-compiles
for both armhf (v7l+) and arm64 (v8+).

Build system entries (Kconfig, Makefile, defconfig) are injected into
the vanilla kernel tree at build time rather than stored as complete
file replacements. This means kernel point-release bumps require only
a new commit hash - no patch regeneration or file re-export.

See [BUILD-MANIFEST.md](BUILD-MANIFEST.md) for the full technical
specification of the injection approach.

## Adding a new kernel point release

1. Find the rpi-firmware commit hash for the target version
2. Add a case entry in `download_build.sh` and `re-build.sh`
3. Build

No other changes needed if the source files are unchanged.

For a kernel published only as Raspberry Pi OS packages, add the case entry
in `build_rpt.sh` instead: the names and sha256 checksums of the source
tarball, the packaging tarball and the two headers packages.

## Related repositories

- [motivo-drivers](https://github.com/volumio/motivo-drivers) -
  legacy repo for kernel 5.10 through 6.6 (frozen)

## License

This project is licensed under the
[GNU General Public License v2.0 or later](LICENSE).

Copyright (C) 2024 VOLUMIO SRL
