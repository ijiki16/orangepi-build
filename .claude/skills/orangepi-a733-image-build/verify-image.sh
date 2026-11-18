#!/usr/bin/env bash
# Verify an Orange Pi A733 (sun60iw2) image without mounting it or needing root.
# Usage: bash verify-image.sh <path/to/image.img> [dtb-name]
#   dtb-name defaults to sun60i-a733-orangepi-4-pro.dtb
# Needs: sfdisk, dd, sha256sum on the host; reads ext4 with debugfs inside orangepi:latest.
set -uo pipefail

img=$(realpath "${1:?usage: verify-image.sh <image.img> [dtb-name]}")
dtb=${2:-sun60i-a733-orangepi-4-pro.dtb}
fail=0
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
inf() { printf 'INFO  %s\n' "$*"; }

# 1. checksum (the .sha lists a bare file name, so check from the image's directory)
if [[ -f $img.sha ]]; then
	(cd "$(dirname "$img")" && sha256sum -c --quiet "$(basename "$img").sha") && ok "sha256 matches" || bad "sha256 mismatch"
else
	inf "no .sha file"
fi

# 2. partition: one Linux partition; orangepi-build uses OFFSET=32 MiB (sector 65536)
start=$(sfdisk -d "$img" 2>/dev/null | awk -F'[=,]' '/start=/{gsub(/ /,"",$2); print $2; exit}')
[[ -n $start ]] && ok "rootfs partition starts at sector $start ($((start / 2048)) MiB)" || { bad "no partition table"; exit 1; }
[[ $start == 65536 ]] || inf "expected sector 65536 for sun60iw2"

# 3. boot chain: boot0 at 8 KiB (eGON magic at +4), boot_package at 8k*2050 = 16400 KiB
[[ $(dd if="$img" bs=1 skip=8196 count=8 status=none) == eGON.BT0 ]] && ok "boot0 (eGON.BT0) at 8 KiB" || bad "boot0 missing at 8 KiB"
dd if="$img" bs=1k skip=16400 count=1 status=none | grep -aq sunxi-package && ok "boot_package at 16400 KiB" || bad "boot_package missing at 16400 KiB"

# 4. rootfs contents via debugfs ("file?offset=N" is understood by e2fsprogs' unix io manager)
report=$(docker run --rm -v "$(dirname "$img"):/i:ro" --entrypoint bash orangepi:latest -c '
	I="/i/'"$(basename "$img")"'?offset='"$((start * 512))"'"
	d() { debugfs -R "$1" "$I" 2>/dev/null; }
	ls1() { d "ls $1" | tr -s " " "\n" | grep -v "^$"; }
	echo "BOOT $(ls1 /boot | grep -xE "uImage|uInitrd|boot.scr|orangepiEnv.txt" | sort | tr "\n" " ")"
	echo "DTB $(ls1 /boot/dtb/allwinner | grep -c -x "'"$dtb"'")"
	echo "OS $(d "cat /etc/os-release" | sed -n "s/^PRETTY_NAME=//p")"
	echo "KVER $(ls1 /lib/modules | grep -vE "^\.|^[0-9]+$|^\(" | tr "\n" " ")"
	d "cat /var/lib/dpkg/status" | awk "/^Package:/{p=\$2} /^Status:.*ok installed/{print p}" > /tmp/pk
	echo "PKGCOUNT $(wc -l < /tmp/pk)"
	for p in u-boot-tools linux-image-current-sun60iw2 linux-dtb-current-sun60iw2 linux-u-boot-orangepi4pro-current openssh-server network-manager xserver-xorg-core lightdm xfce4; do
		grep -qx "$p" /tmp/pk && echo "PKG $p yes" || echo "PKG $p no"; done
	k=$(ls1 /lib/modules | grep sun60iw2 | head -1)
	echo "GPU pvrsrvkm.ko $(ls1 /lib/modules/$k/extra 2>/dev/null | grep -c -x pvrsrvkm.ko)"
	echo "GPU rgx-firmware $(ls1 /lib/firmware | grep -c -x "rgx.fw.36.56.104.183")"
	for f in libsrv_um.so libVK_IMG.so libGLESv2_PVR_MESA.so libPVROCL.so; do echo "GPU $f $(ls1 /usr/lib | grep -c -x $f)"; done
	echo "GPU pvr_dri.so $(ls1 /usr/local/lib/dri 2>/dev/null | grep -c -x pvr_dri.so)"
	echo "GPU img_icd.json $(ls1 /usr/share/vulkan/icd.d 2>/dev/null | grep -c -x img_icd.json)"
	echo "GPU libcedarc $(grep -c -E "^libcedarc-dev" /tmp/pk)"   # vendor name: libcedarc-dev-2.0.0-arm64
')

boot=$(sed -n 's/^BOOT //p' <<<"$report")
[[ $(wc -w <<<"$boot") -eq 4 ]] && ok "/boot: $boot" || bad "/boot incomplete: '$boot'"
[[ $(sed -n 's/^DTB //p' <<<"$report") == 1 ]] && ok "DTB $dtb present" || bad "DTB $dtb missing"
inf "OS $(sed -n 's/^OS //p' <<<"$report"); kernel $(sed -n 's/^KVER //p' <<<"$report"); $(sed -n 's/^PKGCOUNT //p' <<<"$report") packages"
while read -r _ p v; do
	case $p in
		u-boot-tools|linux-image-*|linux-dtb-*|linux-u-boot-*|openssh-server)
			[[ $v == yes ]] && ok "package $p" || bad "package $p missing (main package install aborted?)";;
		*) inf "package $p: $v";;
	esac
done < <(grep '^PKG ' <<<"$report")

gpu_have=$(grep '^GPU ' <<<"$report" | awk '$3>0{print $2}' | tr '\n' ' ')
gpu_miss=$(grep '^GPU ' <<<"$report" | awk '$3==0{print $2}' | tr '\n' ' ')
if [[ -z $gpu_miss ]]; then ok "GPU/VPU stack complete: $gpu_have"
elif [[ -z $gpu_have ]]; then inf "no GPU stack (expected for server images)"
else inf "GPU stack PARTIAL - present: ${gpu_have:-none} | missing: $gpu_miss"; fi

exit $fail
