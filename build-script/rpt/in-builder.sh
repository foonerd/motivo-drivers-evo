#!/bin/bash
# Steps of build_rpt.sh that run inside a builder container.
#
#   in-builder.sh fetch              download and verify the kernel source
#                                    and headers, prepare the source tree
#   in-builder.sh modules <flavour>  build the modules for rpi-v7l or rpi-v8
#   in-builder.sh pack               compile the overlays, write the archive
set -euo pipefail

ROOT=/build
WORK="${ROOT}/build-script/linux-${KERNEL_VERSION}-rpt"
DL="${WORK}/dl"
SRC="${WORK}/src"
SET="${ROOT}/source_files/${SOURCE_SET}"
ARCHIVE="modules-rpi-${KERNEL_VERSION}-motivo"
PKG="${WORK}/pkg/${ARCHIVE}"
PANEL_DIR="drivers/gpu/drm/panel"
USB_DIR="sound/usb"

die() {
    echo "error: $*" >&2
    exit 1
}

headers_deb() {
    case $1 in
    rpi-v7l) echo "${HEADERS_V7L} ${HEADERS_V7L_SHA256}" ;;
    rpi-v8) echo "${HEADERS_V8} ${HEADERS_V8_SHA256}" ;;
    *) die "unknown flavour: $1" ;;
    esac
}

# ---- fetch ----

download() { # <file name> <sha256>
    if [ ! -f "${DL}/$1" ]; then
        echo "  -> download $1"
        curl -fL --retry 3 --silent --show-error -o "${DL}/$1.part" "${POOL}/$1"
        mv "${DL}/$1.part" "${DL}/$1"
    fi
    [ "$(sha256sum "${DL}/$1" | cut -d' ' -f1)" = "$2" ] || die "checksum mismatch for $1"
}

step_fetch() {
    mkdir -p "${DL}"
    download "${ORIG}" "${ORIG_SHA256}"
    download "${PACKAGING}" "${PACKAGING_SHA256}"
    for fl in rpi-v7l rpi-v8; do
        # shellcheck disable=SC2046
        download $(headers_deb "${fl}")
    done

    # The source the kernel packages were built from: the upstream tarball
    # with the packaging's patch series applied.
    if [ ! -f "${SRC}/.prepared" ]; then
        echo "  -> prepare kernel source"
        rm -rf "${SRC}" "${WORK}/packaging"
        mkdir -p "${SRC}" "${WORK}/packaging"
        tar -xJf "${DL}/${ORIG}" -C "${SRC}" --strip-components=1
        tar -xJf "${DL}/${PACKAGING}" -C "${WORK}/packaging"
        while read -r entry _; do
            case ${entry} in '' | '#'*) continue ;; esac
            patch -d "${SRC}" -p1 -s -f --no-backup-if-mismatch \
                <"${WORK}/packaging/debian/patches/${entry}" ||
                die "packaging patch failed to apply: ${entry}"
        done <"${WORK}/packaging/debian/patches/series"
        touch "${SRC}/.prepared"
    fi

    # Configuration and symbol versions of the shipped kernels.
    for fl in rpi-v7l rpi-v8; do
        hdr="${WORK}/headers/${fl}"
        [ -f "${hdr}/Module.symvers" ] && continue
        read -r deb _ <<<"$(headers_deb "${fl}")"
        tmp=$(mktemp -d)
        dpkg-deb -x "${DL}/${deb}" "${tmp}"
        from="${tmp}/usr/src/linux-headers-${RELEASE_BASE}-${fl}"
        [ -f "${from}/.config" ] && [ -f "${from}/Module.symvers" ] ||
            die "${deb} does not carry .config and Module.symvers"
        mkdir -p "${hdr}"
        cp "${from}/.config" "${from}/Module.symvers" "${hdr}/"
        rm -rf "${tmp}"
    done
}

# ---- modules ----

step_modules() {
    local fl=$1 arch cross cc rel out hdr
    case ${fl} in
    rpi-v7l) arch=arm cross=arm-linux-gnueabihf- ;;
    rpi-v8) arch=arm64 cross=aarch64-linux-gnu- ;;
    *) die "unknown flavour: ${fl}" ;;
    esac
    cc="${cross}gcc-12"
    rel="${RELEASE_BASE}-${fl}"
    out="${WORK}/out/${fl}"
    hdr="${WORK}/headers/${fl}"
    [ -f "${SRC}/.prepared" ] && [ -f "${hdr}/Module.symvers" ] || die "run the fetch step first"

    kmake() {
        make -C "${SRC}" O="${out}" ARCH="${arch}" CROSS_COMPILE="${cross}" CC="${cc}" \
            KERNELRELEASE="${rel}" -j"$(nproc)" "$@"
    }
    config_view() {
        grep -E '^(CONFIG_[A-Za-z0-9_]+=|# CONFIG_[A-Za-z0-9_]+ is not set)' "$1" | sort
    }

    # An output tree configured exactly as the shipped kernel. The compiler
    # is part of the configuration: if this builder does not reproduce it,
    # the modules would not be what the kernel expects.
    stamp="${fl}: $("${cc}" --version | head -n1)"
    if [ "$(cat "${out}/.prepared" 2>/dev/null)" != "${stamp}" ]; then
        echo "  -> prepare ${rel}"
        rm -rf "${out}"
        mkdir -p "${out}"
        cp "${hdr}/.config" "${out}/.config"
        kmake olddefconfig >/dev/null
        if ! diff <(config_view "${hdr}/.config") <(config_view "${out}/.config") >"${out}/config.diff"; then
            cat "${out}/config.diff" >&2
            die "${fl}: this builder does not reproduce the configuration of the shipped kernel"
        fi
        kmake modules_prepare >"${out}/prepare.log" 2>&1 ||
            { tail -n 30 "${out}/prepare.log" >&2; die "${fl}: modules_prepare failed"; }
        cp "${hdr}/Module.symvers" "${out}/Module.symvers"
        [ "$(cat "${out}/include/config/kernel.release")" = "${rel}" ] ||
            die "${fl}: the tree does not report release ${rel}"
        echo "${stamp}" >"${out}/.prepared"
    fi

    # build <kernel dir> <module> [make arguments]: build one module from a
    # copy of its kernel directory, staged at its kernel path so that the
    # module records the same source paths as the kernel's own.
    build() {
        local dir=$1 mod=$2 root="${WORK}/stage/${fl}/$2" ko vm
        shift 2
        printf 'obj-y := %s/\n' "${dir}" >"${root}/Kbuild"
        kmake M="${root}" "$@" "${dir}/${mod}.ko" >"${root}/build.log" 2>&1 ||
            { tail -n 40 "${root}/build.log" >&2; die "${fl}: ${mod} failed to build"; }
        ko="${root}/${dir}/${mod}.ko"
        vm=$(modinfo -F vermagic "${ko}")
        [ "${vm%% *}" = "${rel}" ] || die "${fl}: ${mod} is built for '${vm%% *}', not '${rel}'"
        [ -n "$(modprobe --dump-modversions "${ko}" 2>/dev/null)" ] ||
            die "${fl}: ${mod} carries no symbol versions"
        mkdir -p "${PKG}/lib/modules/${rel}/kernel/${dir}"
        "${cross}strip" --strip-debug -o "${PKG}/lib/modules/${rel}/kernel/${dir}/${mod}.ko" "${ko}"
        xz --check=crc32 --lzma2=dict=1MiB -f "${PKG}/lib/modules/${rel}/kernel/${dir}/${mod}.ko"
    }
    stage() { # <kernel dir> <module>: a fresh copy of the kernel directory
        local root="${WORK}/stage/${fl}/$2"
        rm -rf "${root}"
        mkdir -p "${root}/$1"
        cp -a "${SRC}/$1/." "${root}/$1/"
    }
    maps() { echo "-fmacro-prefix-map=${WORK}/stage/${fl}/$1/= -fmacro-prefix-map=${SRC}/="; }

    rm -rf "${PKG}/lib/modules/${rel}"

    # Panel driver: new to the kernel. Its Makefile line is injected into
    # the staged copy and its symbol switched on for this build.
    echo "  -> ${rel}: panel-dsi-mt"
    stage "${PANEL_DIR}" panel-dsi-mt
    cp "${SET}/panel/panel-dsi-mt.c" "${WORK}/stage/${fl}/panel-dsi-mt/${PANEL_DIR}/"
    if ! grep -q "panel-dsi-mt" "${WORK}/stage/${fl}/panel-dsi-mt/${PANEL_DIR}/Makefile"; then
        echo 'obj-$(CONFIG_DRM_PANEL_DSI_MT) += panel-dsi-mt.o' \
            >>"${WORK}/stage/${fl}/panel-dsi-mt/${PANEL_DIR}/Makefile"
    fi
    build "${PANEL_DIR}" panel-dsi-mt CONFIG_DRM_PANEL_DSI_MT=m \
        KCFLAGS="-DCONFIG_DRM_PANEL_DSI_MT_MODULE=1 $(maps panel-dsi-mt)"

    # USB audio: the kernel's driver with the set's replacement files.
    echo "  -> ${rel}: snd-usb-audio"
    stage "${USB_DIR}" snd-usb-audio
    cp "${SET}"/sound_usb/*.[ch] "${WORK}/stage/${fl}/snd-usb-audio/${USB_DIR}/"
    build "${USB_DIR}" snd-usb-audio KCFLAGS="$(maps snd-usb-audio)"
}

# ---- pack ----

step_pack() {
    for fl in rpi-v7l rpi-v8; do
        for ko in "${PANEL_DIR}/panel-dsi-mt" "${USB_DIR}/snd-usb-audio"; do
            [ -f "${PKG}/lib/modules/${RELEASE_BASE}-${fl}/kernel/${ko}.ko.xz" ] ||
                die "${fl} has not been built"
        done
    done

    # Overlays are the same for every flavour.
    rm -rf "${PKG:?}/boot"
    mkdir -p "${PKG}/boot/overlays"
    for dts in "${SET}"/overlays/*-overlay.dts; do
        name=$(basename "${dts}" -overlay.dts)
        echo "  -> overlay: ${name}"
        cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
            -I "${SRC}/include" -I "${SRC}/arch/arm/boot/dts" "${dts}" |
            dtc -@ -q -I dts -O dtb -o "${PKG}/boot/overlays/${name}.dtbo"
    done

    mkdir -p "${ROOT}/output"
    tar -C "${WORK}/pkg" --sort=name --owner=0 --group=0 --numeric-owner \
        -czf "${ROOT}/output/${ARCHIVE}.tar.gz" "${ARCHIVE}"
    cd "${ROOT}/output"
    md5sum "${ARCHIVE}.tar.gz" >"${ARCHIVE}.md5sum.txt"
    sha1sum "${ARCHIVE}.tar.gz" >"${ARCHIVE}.sha1sum.txt"
    echo "  -> output/${ARCHIVE}.tar.gz"
}

case ${1:-} in
fetch) step_fetch ;;
modules) step_modules "${2:-}" ;;
pack) step_pack ;;
*) die "usage: in-builder.sh fetch | modules <flavour> | pack" ;;
esac
