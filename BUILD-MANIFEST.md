# motivo-drivers-evo

Custom kernel module build for Motivo hardware.
Successor to motivo-drivers (which remains frozen for legacy kernels).

## Design principle

source_files/ contains ONLY Motivo-authored or Motivo-modified code.
Build system scaffolding (Kconfig, Makefile, defconfig) is injected by
the build script against the vanilla kernel tree, never stored as
complete file replacements.

## Repository layout

    motivo-drivers-evo/
      README.md
      LICENSE
      BUILD-MANIFEST.md
      .gitignore
      build-script/
        download_build.sh
        re-build.sh
        install_deps.sh
      source_files/
        6.12.y/
          panel/
            panel-dsi-mt.c
          overlays/
            motivo-panel-a-overlay.dts
            motivo-panel-b-overlay.dts
            es9039q2m-i2s-overlay.dts
          sound_usb/
            quirks.c
      output/
        .gitkeep


## What is injected by the script

| Target file                         | Method                              | Idempotent |
|-------------------------------------|-------------------------------------|------------|
| drivers/gpu/drm/panel/Kconfig       | sed insert before "endmenu"         | yes        |
| drivers/gpu/drm/panel/Makefile      | append to end of file               | yes        |
| arch/arm/boot/dts/overlays/Makefile | sed insert after last .dtbo entry   | yes        |
| .config (both arch)                 | scripts/config --module after make  | yes        |

All injections check for existing entries before modifying (grep guard).

## What ships in the archive

    modules-rpi-{version}-motivo.tar.gz
      boot/overlays/
        motivo-panel-a.dtbo
        motivo-panel-b.dtbo
        es9039q2m-i2s.dtbo
      lib/modules/{version}-v7l+/kernel/
        drivers/gpu/drm/panel/panel-dsi-mt.ko.xz
        sound/usb/snd-usb-audio.ko.xz
      lib/modules/{version}-v8+/kernel/
        drivers/gpu/drm/panel/panel-dsi-mt.ko.xz
        sound/usb/snd-usb-audio.ko.xz

Removed from V4 archive (stock kernel versions are fine on 6.12):
- panel-ilitek-ili9881c.ko
- drm_panel_orientation_quirks.ko

## Kernels published only as Raspberry Pi OS packages

6.12.115 exists only as Raspberry Pi OS packages and is built by
build-script/build_rpt.sh. What differs from download_build.sh:

|                 | download_build.sh                    | build_rpt.sh                                   |
|-----------------|--------------------------------------|------------------------------------------------|
| Kernel source   | raspberrypi/linux at the rpi-firmware commit | upstream tarball plus the package's patch series, sha256 verified |
| Configuration   | bcm2711_defconfig                    | the shipped kernel's own, from its headers package |
| Symbol versions | from building the whole kernel       | the shipped kernel's Module.symvers            |
| Compiler        | cross compilers on the build host    | the distribution and compiler that built the kernel, in a container |
| What is built   | kernel, all modules, dtbs            | the two modules and the three overlays         |
| Kernel releases | {version}-v7l+, {version}-v8+        | {version}+rpt-rpi-v7l, {version}+rpt-rpi-v8    |

The build stops unless the container reproduces the shipped kernel's
configuration exactly, each module reports exactly the kernel release it is
packed for, and each module carries symbol versions.

The Makefile line for panel-dsi-mt is injected into a staged copy of the
panel directory. Kconfig.inject is not read by this build: the symbol is
passed on the make command line.

Every file in the set's sound_usb/ replaces the kernel's file of the same
name. The 6.12.115 set holds quirks.c, endpoint.c and stream.c.

    modules-rpi-6.12.115-motivo.tar.gz
      boot/overlays/
        motivo-panel-a.dtbo
        motivo-panel-b.dtbo
        es9039q2m-i2s.dtbo
      lib/modules/6.12.115+rpt-rpi-v7l/kernel/
        drivers/gpu/drm/panel/panel-dsi-mt.ko.xz
        sound/usb/snd-usb-audio.ko.xz
      lib/modules/6.12.115+rpt-rpi-v8/kernel/
        drivers/gpu/drm/panel/panel-dsi-mt.ko.xz
        sound/usb/snd-usb-audio.ko.xz

Adding a later kernel of this kind:

1. Create source_files/{version}/ from the previous set; carry each file
   in sound_usb/ onto that kernel's stock file
2. Add a case entry in build_rpt.sh with the names and sha256 checksums of
   the source tarball, the packaging tarball and the two headers packages
3. Build

## Why quirks.c remains a replacement

The DSD VENDOR_FLG entries sit in the middle of a static const array in
quirks.c. There is no clean insertion point (like "endmenu" for Kconfig).
Upstream also adds entries to the same array between point releases. A
fragment-based injection would risk duplicates or misplaced entries.

## Adding a new kernel point release (same series)

Example: adding 6.12.50 when 6.12.47 already works.

1. Find the rpi-firmware commit hash for 6.12.50
2. Add one case entry in download_build.sh and re-build.sh:
     "6.12.50")
       KERNEL_COMMIT="<hash>"
       SOURCE_SET="6.12.y"
       ;;
3. Build. No other changes needed.

## Adding a new kernel series

Example: moving from 6.12 to 6.18.

1. Create source_files/6.18.y/
2. Copy panel-dsi-mt.c (verify against new drm_panel_funcs API)
3. Copy overlay .dts files (likely unchanged)
4. Generate new quirks.c (apply DSD entries to stock 6.18 quirks.c)
5. Add case entry with SOURCE_SET="6.18.y"
6. Build and validate

## Verification checklist for new kernel series

- [ ] Kconfig still ends with "endmenu" (injection anchor)
- [ ] Panel Makefile still uses obj-$(CONFIG_...) pattern
- [ ] Overlays Makefile still uses tab-indented .dtbo continuation lines
- [ ] drm_panel_funcs callbacks match panel-dsi-mt.c
- [ ] drm_panel_init() signature unchanged
- [ ] mipi_dsi_dcs_write() parameter types unchanged
- [ ] prepare_prev_first field present in struct drm_panel
- [ ] Module compression still xz (not zstd)
- [ ] scripts/config tool still works after make defconfig

## Repository separation

- motivo-drivers-evo: new repo, kernel 6.12+ only, active development
- motivo-drivers:     existing repo, frozen, legacy kernels 5.10 through 6.6
