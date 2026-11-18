---
name: orangepi-a733-image-build
description: Use when building, debugging or checking orangepi-build images for Allwinner A733 / sun60iw2 boards (Orange Pi 4 Pro, Zero 3W, Zero 4), for any Debian release (bullseye, bookworm, trixie), when working on the mainline 7.4 kernel or Armbian edge branch for the 4 Pro, or when asked whether the PowerVR BXM GPU works. Also use on errors like "unsupported build system", "GLIBC_2.38 not found" in modpost, kernel postinst exit status 127, "Unable to locate package", a desktop falling back to llvmpipe, "MDIO device at address 1 is missing", "Failed to reset the dma", "no support for card's volts", FDT_ERR_NOSPACE, or a hang after "Starting kernel".
---

# Orange Pi A733 (sun60iw2) image build

## Overview

`orangepi-build` for sun60iw2 has several failure modes that **don't stop the build**: apt index rollbacks, skipped vendor packages, and a rootfs cache saved after a failed install. A green "Done building" therefore proves nothing. Every image is verified, and every warning in the log is traced, before the build is called done.

Background: `docs/a733/building.md` covers each failure in depth, `docs/a733/gpu.md` covers the GPU stack and other boards, and `docs/a733/mainline.md` covers the mainline 7.4 port.

## Running a build

0. Check the prerequisites once per host:
   - `id -nG` lists `docker`
   - `cat /proc/sys/fs/binfmt_misc/qemu-aarch64` shows `enabled` and flags containing `F`
   - `grep -c sun60iw2_pkgdir external/config/sources/families/sun60iw2.conf` is > 0. If it is 0, the bullseye vendor path fix is missing; see building.md §4.

   If Docker or binfmt is missing, ask the user to set it up. It needs sudo, which agents don't have; the user can run it with the `!` prefix.
1. Build inside the container with `run-build.sh`, never with native `./build.sh` on a host other than focal/jammy/noble, and never with `./build.sh docker` (that uses `docker run -it`, which needs a TTY). Run it in the background; a build takes 25–35 min.
   ```bash
   bash .claude/skills/orangepi-a733-image-build/run-build.sh <scratch>/build-<release>.log \
     BOARD=orangepi4pro BRANCH=current RELEASE=<bullseye|bookworm|trixie> BUILD_OPT=image \
     BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no DOWNLOAD_MIRROR=eu IGNORE_UPDATES=yes \
     COMPRESS_OUTPUTIMAGE=sha,img
   # desktop: BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce DESKTOP_ENVIRONMENT_CONFIG_NAME=config_base DESKTOP_APPGROUPS_SELECTED=
   ```
   - `<scratch>` is the session scratchpad directory. Keep one log per release.
   - Several releases run **one after another** in a single background command (a `for R in …` loop), never in parallel: they share `kernel/`, `output/debs` and `.tmp`.
   - The first build on a host compiles the kernel and later ones rebuild it incrementally. Times above assume a warm tree.
   - When the user asks for a desktop release whose GPU row below isn't "complete", say so before building.
2. Read the summary `run-build.sh` prints:
   - the `[ error ]`/`[ warn ]` lines
   - the silent-failure lines
   - errors from `install.log`, which it copies to `<log>.install.log`

   Treat these lines as failures even when the exit status is 0:
   - `Unable to locate package`
   - `Failed to fetch`
   - `Updating package lists [ failed ]`
   - `vendor package dir missing`
   - error lines in `<log>.install.log`

   If a later step fails but this log has no apt error, the run probably reused a broken rootfs cache. The sign is an `Extracting <release>-…tar.lz4 [ N days old ]` line in place of `Installing base system`. The original error is in the log of the run that wrote that cache file. Fix it as in building.md §3.
3. Check the image. The path is in the `Done building [ /root/orangepi/output/images/… ]` line, with `/root/orangepi` meaning the repo root:
   ```bash
   bash .claude/skills/orangepi-a733-image-build/verify-image.sh output/images/<name>/<name>.img
   ```
   - The image is good only if no line says `FAIL`. Exit status 1 means at least one did.
   - GPU results are always `INFO` lines, never `FAIL`. Compare the GPU line with the row for that release below and quote it as printed. A `PARTIAL` that matches the table is expected, not a regression.
4. Report the image path, the verify results, and the GPU status for the release (table below). Say that the image was not booted on hardware.

## Symptom → cause → fix

| Symptom | Root cause | Fix |
|---|---|---|
| `unsupported build system: <codename>` | the host release is not focal/jammy/noble | `run-build.sh` (container) |
| `scripts/mod/modpost: … GLIBC_2.38' not found` | stale host tools in `kernel/<tree>` from an earlier native build | delete `scripts/mod/{modpost,*.o,.*.cmd}`, then check the other x86 tools' glibc (command in building.md §1) |
| kernel deb `post-installation script … exit status 127` | `mkimage` missing because the main `apt-get install` aborted earlier | find the earlier `Unable to locate package X` and fix that, not the postinst |
| `Unable to locate package iozone3` (or another non-free package) | the mirror has no **armhf**; one 404 makes apt roll back every index of the suite | find the mirror in the `Failed to fetch … binary-armhf` line. `eu` already falls back to `deb.debian.org` when grena lacks armhf; any other mirror needs armhf. Reproduce with building.md §2, using that release and mirror. |
| `Certificate verification failed: … name in the certificate does not match` (bullseye) | bullseye's sources use `https://`; `ftp.nl.debian.org` is an alias whose cert covers only `*.snt.utwente.nl` | any https fallback mirror needs a valid cert; `eu` now falls back to `deb.debian.org` (building.md §5) |
| `Failed to fetch …debian-security/pool/… 404` (bullseye), `Upgrading base packages [ failed ]` | EOL suite moved to `archive.debian.org`; mirrors keep the index but drop the pool | bullseye security now points to `archive.debian.org` (building.md §6). Check other suites the same way once they reach EOL. |
| `Installation of vlc failed`, `depends on vlc-data (= X)` | vendor deb pins an older VLC than the release now ships | the VLC alignment step in `family_tweaks_s` (building.md §7). The rootfs cache is fine here; don't delete it. |
| later builds keep failing the same way | a broken rootfs cache was saved (`debootstrap.sh:326` PIPESTATUS bug) | delete the cache files whose timestamp matches the failed run, using the full command in building.md §3 |
| desktop image has no `rgx.fw`, `libVK_IMG`, `pvr_dri.so` | vendor repo layout `bullseye/<pkg>` vs the script's flat paths; release not in the GPU branch | `sun60iw2_pkgdir` resolver (bullseye). For bookworm/trixie, port Armbian's `post_family_tweaks__sun60iw2_userspace` (gpu.md) |
| Chrome blank or software-only on trixie | launcher forced to `--use-angle=vulkan` with no Vulkan driver | install the GPU userspace, or remove the flags from `/opt/google/chrome/google-chrome` |

## GPU per release (orangepi-build, desktop images)

| Release | Expected result of `verify-image.sh` |
|---|---|
| bullseye | complete (relies on the `sun60iw2_pkgdir` fix in this tree; step 0 checks it) |
| bookworm | no `pvrsrvkm.ko` either: PARTIAL (only `img_icd.json`); `vendor package dir missing` warnings are expected |
| trixie | `pvrsrvkm.ko` only: PARTIAL (no firmware, so the GPU cannot start) |
| server, any release | no `pvrsrvkm.ko` |

Every vendor (Orange Pi, Radxa, Armbian) ships the same blob: `xserver-xorg-img-bxm_1.21.1-2_arm64.deb`, SHA-256 `c8e606db…`, DDK 24.2.6603887. On bookworm/trixie its patched Xorg also needs `libcrypto.so.1.1`.

## Mainline / upstream questions

For the GPU, answer from the "Mainline status" section of `docs/a733/gpu.md`, and re-check the sources it lists when the answer has to be current. As of 2026-11-18:

| Kernel | A733 GPU |
|---|---|
| upstream mainline / linux-next | **no**: BVNC 36.56.104.183 is unknown to `drm/imagination`, there's no Allwinner GPU compatible and no CCU/dtsi merged, and the firmware is only in Imagination's staging repo |
| TumRedSun/orangepi4pro-linux (7.3 + 21 patches, Orange Pi 4 Pro) | GPU node exists (`allwinner,sun60i-a733-gpu`); `powervr.ko` **freezes the board**, so it's disabled. NVMe, GMAC, HDMI (vendor out-of-tree port) and AIC8800 work. |
| ijiki16/orangepi4pro-linux (7.4-rc3+ and 35 patches, Armbian `edge`) | GPU node **disabled** on purpose: udev autoloads `powervr.ko` and the board hangs. SD, Ethernet and the AXP318W PMIC work; no HDMI or Wi-Fi/BT. |
| vendor 6.6 BSP (this build) + apercel | open driver, reported working (Vulkan, zink GL, Wayland) |
| vendor 6.6 BSP + closed DDK 24.2 | what orangepi-build ships; complete only on bullseye |

Say which kernel a claim applies to. "Works on the 4 Pro" is true for the vendor 6.6 kernel and false for mainline.

## Mainline 7.4 kernel (Armbian `edge`)

The code is in `ijiki16/orangepi4pro-linux` (branch `rebase-7.4-rc3`) and `ijiki16/build` (branch `sun60iw2-mainline-edge`). `docs/a733/mainline.md` has the build commands, board facts, register addresses and the full failure table.

1. Build from the `sun60iw2-mainline-edge` checkout:
   ```bash
   ./compile.sh build BOARD=orangepi4pro BRANCH=edge RELEASE=trixie BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no COMPRESS_OUTPUTIMAGE=sha,img
   ```
2. In the build log, confirm `kernel patching: N total patches; N applied; 0 with problems`.
3. On the booted board, copy `check-mainline-board.sh` over and run `sudo bash check-mainline-board.sh`. The board is good only if no line says `FAIL`.
4. Report what was tested on hardware. Name gigabit Ethernet as untested unless the link partner offered 1000 Mb/s.

| Symptom (mainline) | Root cause | Fix |
|---|---|---|
| `could not set bootargs FDT_ERR_NOSPACE` in U-Boot | DTB has no free space for `/chosen` | `DTC_FLAGS_<dtb> := -p 16384` |
| Silence after `Starting kernel ...` | initrd moved onto BL31 at `0x48000000` | `setenv fdt_high 0xffffffff`, `setenv initrd_high 0xffffffff` |
| Hard hang about 8 s into boot | udev autoloads `powervr.ko` | `&gpu { status = "disabled"; }` |
| `pin PF2 already requested by 2500000.serial` | dtsi muxes UART0 onto SD pins | delete `pinctrl-0` from `&uart0` |
| `no support for card's volts` | mmc0 has no `vmmc-supply` | PMIC `SWOUT2` |
| `MDIO device at address 1 is missing` | PHY rail `SWOUT1` off, glue register lost in reset, or MDC too fast | AXP318W driver with `phy-supply`, the dwmac-sun60i glue fix, `snps,clk-csr = <4>` |
| `setup of GPIO reset failed: -517`, retried forever | PHY reset on PA14; the A733 has no port A | `reset-gpios` on PH16 |
| `Failed to reset the dma` | PHY `CLK_OUT` disabled | `motorcomm,clk-out-frequency-hz = <125000000>` |
| Link up, RX stays near 0, no DHCP | RXC delay cleared by `phy-mode = "rgmii"` | `rgmii-id`, `rx-internal-delay-ps = <1900>`, `tx-internal-delay-ps = <150>` |
| `pll-ref` reads 22.15 MHz | PLL input modelled as 24 MHz; the crystal is 26 MHz | `dcxo` clock at 26 MHz feeding `pll-ref` |

## Common mistakes

- **Reporting success from the exit status or "Done building".** Run `verify-image.sh` first.
- **Fixing the last error in the log.** The kernel postinst error is a downstream effect; the cause is the first apt error above it.
- **Rebuilding without deleting the cache** after a failed package install, which brings the broken rootfs back.
- **Editing `sun60iw2.conf` while a build runs.** The running build already sourced it; stop the build, edit, restart.
- **Saying "the GPU works" because `pvrsrvkm.ko` is present.** Without `rgx.fw.36.56.104.183` and the userspace libraries it does nothing.
- **Assuming the card runs the newest build.** Read the running kernel first: `check-mainline-board.sh` fails on `dcxo rate` when an older kernel is booted.
- **Setting `osc24M` to 26 MHz.** That clock is `SYS_CLK24M` and stays at 24 MHz. Only `pll-ref` and the RTC `hosc` use the crystal.
- **Mixing firmware.** The vendor stack uses `rgx.fw.*`; the open apercel driver uses `rogue_36.56.104.183_v1.fw`.
- **Deleting root-owned files in `output/` or `external/cache`** with sudo (not available). Use `docker run --rm -v …:/x --entrypoint sh orangepi:latest -c 'rm …'`.
