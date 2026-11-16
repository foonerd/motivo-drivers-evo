#!/bin/bash
# Build the Motivo modules and overlays for a kernel that Raspberry Pi
# publishes only as Raspberry Pi OS packages (6.12.115 and later). Such a
# kernel has no rpi-firmware commit, so download_build.sh cannot build it.
#
# The modules are built against the shipped kernel, not against a rebuilt
# one: its configuration and symbol versions come from the kernel's headers
# packages, and each flavour is compiled in a container of the distribution,
# architecture and compiler that built it.
#
# Needs docker, and qemu-user-static registered with binfmt.
set -euo pipefail

KERNEL_VERSION="6.12.115"

# ---- Version configuration ----
# One case entry per kernel version. File names and checksums are in the
# Sources and Packages indexes of archive.raspberrypi.com.

case $KERNEL_VERSION in
    "6.12.115")
      SOURCE_SET="6.12.115"
      RELEASE_BASE="6.12.115+rpt"
      ORIG="linux_6.12.115.orig.tar.xz"
      ORIG_SHA256="0ec90fe4b20422b1b664b77e6d2dde22b40bd41e7eb2cad8ac8739a4749cb1bb"
      PACKAGING="linux_6.12.115-1+rpt1.debian.tar.xz"
      PACKAGING_SHA256="a302a3f46bdbac0dd858872b55157b377fefa7c8c7d0c4e018a3a0a0e2728d82"
      HEADERS_V7L="linux-headers-6.12.115+rpt-rpi-v7l_6.12.115-1+rpt1_armhf.deb"
      HEADERS_V7L_SHA256="fdb8113ef2f10399191b8ce622745721e73680fa5bb518453709a800892d6b6a"
      HEADERS_V8="linux-headers-6.12.115+rpt-rpi-v8_6.12.115-1+rpt1_arm64.deb"
      HEADERS_V8_SHA256="3df5cc99ff01a57edbd8869941f437be4d00c1e4b11f91e700fff26cc6783bf3"
      ;;
    *)
      echo "no configuration for kernel ${KERNEL_VERSION}" >&2
      exit 1
      ;;
esac
POOL="https://archive.raspberrypi.com/debian/pool/main/l/linux"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "!!!  Build modules for kernel ${KERNEL_VERSION} (${RELEASE_BASE})  !!!"
echo "!!!  Source set: ${SOURCE_SET}  !!!"

# in_builder <builder> <platform> <step> [flavour]: run one step of
# rpt/in-builder.sh inside a builder. The repository is always mounted at
# /build, so the modules do not record where it is checked out.
in_builder() {
    local builder=$1 platform=$2
    shift 2
    docker build -q --platform "${platform}" -t "motivo-drivers-evo:${builder}" \
        "${SCRIPT_DIR}/rpt/${builder}" >/dev/null
    docker run --rm --platform "${platform}" --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -e KERNEL_VERSION="${KERNEL_VERSION}" -e SOURCE_SET="${SOURCE_SET}" \
        -e RELEASE_BASE="${RELEASE_BASE}" -e POOL="${POOL}" \
        -e ORIG="${ORIG}" -e ORIG_SHA256="${ORIG_SHA256}" \
        -e PACKAGING="${PACKAGING}" -e PACKAGING_SHA256="${PACKAGING_SHA256}" \
        -e HEADERS_V7L="${HEADERS_V7L}" -e HEADERS_V7L_SHA256="${HEADERS_V7L_SHA256}" \
        -e HEADERS_V8="${HEADERS_V8}" -e HEADERS_V8_SHA256="${HEADERS_V8_SHA256}" \
        -v "${ROOT}:/build" -w /build "motivo-drivers-evo:${builder}" \
        build-script/rpt/in-builder.sh "$@"
}

in_builder bookworm-arm64 linux/arm64 fetch

echo "!!!  Build CM4 32-bit modules  !!!"
in_builder bookworm-raspbian-armhf linux/arm/v7 modules rpi-v7l

echo "!!!  Build CM4 64-bit modules  !!!"
in_builder bookworm-arm64 linux/arm64 modules rpi-v8

echo "!!!  Creating archive  !!!"
in_builder bookworm-arm64 linux/arm64 pack

echo "!!!  Done  !!!"
