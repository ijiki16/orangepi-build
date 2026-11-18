# Allwinner A733 GPU (PowerVR BXM-4-64) on Debian

How the GPU stack fits together on the Orange Pi 4 Pro, what each Debian release gets, and how other A733 boards and distributions handle it.
Researched 2026-11-16. Community claims are taken from project READMEs and were not tested on hardware here.

## Hardware

| | |
|---|---|
| GPU | Imagination BXM-4-64 MC1, BVNC **36.56.104.183** |
| DT node | `gpu@1800000`, `compatible = "img,gpu"`, IRQs 63 (GPU) and 64 (DVFS), power domain `SUN60IW2_PCK_GPU_TOP` |
| DVFS | `gpu_opp_table`: 300 / 400 / 600 MHz @ 800 mV, 800 MHz @ 840 mV, 1008 MHz @ 960 mV |
| Supply | `gpu-supply = <&reg_dcdc4>` (AXP8191 DCDC4) |
| APIs (vendor) | OpenGL ES 3.2, Vulkan 1.3.277, OpenCL 3.0 |

Note the BVNC: mainline `drm/imagination` lists BXM-4-64 MC1 as 36.52.104.182, which is a different core variant.

## The closed vendor stack (DDK 24.2.6603887)

| Layer | What it is | Where it comes from |
|---|---|---|
| Kernel driver | `pvrsrvkm.ko`, rogue, `WINDOW_SYSTEM=nulldrmws`, native fence sync + dma-buf | Built out of tree from `kernel/…/bsp/modules/gpu/img-bxm/linux/rogue_km` (`scripts/compilation.sh:528`). Installed to `/lib/modules/<ver>/extra` on desktop builds only. Loaded through `MODULES=… pvrsrvkm`. |
| Firmware | `/lib/firmware/rgx.fw.36.56.104.183`, `rgx.sh.36.56.104.183` | **Only** in `xserver-xorg-img-bxm`. Without this package the driver loads but can't start the GPU. |
| Core libs | `libsrv_um`, `libusc`, `libglslcompiler`, `libufwriter`, `libpvr_dri_support`, `libsutu_display` in `/usr/lib` | `xserver-xorg-img-bxm` |
| GLES / EGL / GBM | `libGLESv2_PVR_MESA`, `libGLESv1_CM_PVR_MESA` in `/usr/lib`; an IMG-patched Mesa in `/usr/local/lib` (`libEGL`, `libgbm`, `libGLESv2`, `libglapi`, `libpvr_mesa_wsi`, `dri/pvr_dri.so`) | `xserver-xorg-img-bxm`. `/etc/ld.so.conf.d/00-pvr-priority.conf` puts `/usr/local/lib` ahead of `/usr/lib`. |
| Vulkan | `libVK_IMG.so` with `/usr/share/vulkan/icd.d/img_icd.json` → `/lib/libVK_IMG.so` | lib from the deb, ICD from `external/packages/bsp/sun60iw2` |
| OpenCL | `libPVROCL.so` with `/etc/OpenCL/vendors/pvr.icd` | same |
| X server | patched Xorg 1.21.1 (COMPOSITE), modesetting + glamor, `DRI 2`, `kmsdev /dev/dri/card0` (`20-modesetting.conf`) | `xserver-xorg-img-bxm` |
| Display | Allwinner vendor DRM (`AW_DRM*`) on `card0`; the GPU renders only, through `renderD128` | kernel |
| Video / camera | `libcedarc` + `gstreamer1.0-omx-allwinner`, `libAWIspApi` | `sun60iw2_packages/bullseye/*` |

What the userspace needs from the system:
- the blobs: glibc ≤ 2.30, libdrm, libX11/xcb (`libxcb-dri2/3`, `present`, `sync`, `randr`, `xfixes`), `libxshmfence`, `libexpat`, `libstdc++`
- the patched **Xorg binary**: also **`libcrypto.so.1.1`** (OpenSSL 1.1, which bookworm and trixie no longer ship)

The kernel driver and userspace versions must match exactly. Both are 24.2.6603887 here.

### Is there a newer DDK? (checked 2026-11-16: no)

| Source | DDK |
|---|---|
| `orangepi-xunlong/linux-orangepi@orange-pi-6.6-sun60iw2` head `2ac08e8c7` (2026-09-17) | 24.2@6603887 |
| `radxa/allwinner-bsp@cubie-aiot-v1.5.0` and `@main` | 24.2@6603887 |
| Radxa `img-bxm-dkms` 0.1.0-3 (package contents) | 24.2@6603887 |
| `radxa-pkg/aw-drivers-dkms` changelog | unreleased 1.4.9-1 only moves to cubie-aiot-v1.5.0 (still 24.2) |

Imagination ships newer DDKs to other SoC vendors: TI went from 25.2 to 25.3 to 26.1 (proposed in meta-ti, 2026-06). They can't be mixed in here:
- the kernel module and userspace must come from the same DDK build
- the firmware is built per BVNC
- the blobs are licensed per SoC vendor

A newer A733 driver would come from an Allwinner BSP update, through Orange Pi or Radxa.
To check again:

```bash
curl -sL https://raw.githubusercontent.com/orangepi-xunlong/linux-orangepi/orange-pi-6.6-sun60iw2/bsp/modules/gpu/img-bxm/linux/rogue_km/include/pvrversion.h | grep STRING_SHORT
curl -sL https://raw.githubusercontent.com/radxa/allwinner-bsp/main/modules/gpu/img-bxm/linux/rogue_km/include/pvrversion.h | grep STRING_SHORT
curl -sL https://radxa-repo.github.io/a733-trixie/dists/a733-trixie/main/binary-arm64/Packages | grep -A1 -E '^Package: (img-bxm|xserver-xorg-img)'
```

## Mainline status (checked 2026-11-16)

| Piece | Status for A733 (BVNC 36.56.104.183) |
|---|---|
| Kernel `drm/imagination` (7.4-rc3, linux-next, sunxi tree) | **Not supported.** `pvr_gpu_support_level()` lists only 33.15.11.3, 36.52.104.182 and 36.53.104.796, so this core is `PVR_GPU_UNKNOWN` ("Unknown GPU!") and needs `powervr.exp_hw_support=1`. No Allwinner compatible in `img,powervr-rogue.yaml` (the BXM-4-64 entry is for `spacemit,k3-gpu` and `thead,th1520-gpu`). No dri-devel patches for 36.56 found. |
| Firmware | `rogue_36.56.104.183_v1.fw` is in Imagination's staging repo (`gitlab.freedesktop.org/imagination/linux-firmware`, branch `powervr`; added 2025-09-17, updated 2026-04-15). **Not** in upstream linux-firmware yet. |
| Mesa PowerVR Vulkan | Device info added 2025-10-11 (`1db1038a`, so in releases since 25.3; current 26.3.0). **Non-conformant**: it needs `PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1`. There's no native GL driver; GL/GLES go through zink. |
| A733 SoC in mainline | pinctrl (`pinctrl-sun60i-a733.c`) and the GPU power domain (`allwinner,sun60i-a733-pck-600` in `sun55i-pck600.c`) are merged. **Not merged:** the CCU clock driver (v7 posted 2026-11-12, awaiting upstream), the SoC dtsi (v3, 2026-11-10), board DTs (Cubie A7Z), USB PHY. There's no GPU DT node anywhere. |

So upstream mainline can't drive the A733 GPU yet: it lacks the clocks, the device tree and GPU support for this core. The out-of-tree 7.3 port below has the clocks and the GPU node, but its `powervr` load still freezes the board. Today the open route is apercel. It is an out-of-tree port of `drm/imagination` that runs on the vendor 6.6 kernel, with the staging firmware and a patched Mesa.

### Community mainline bring-up: TumRedSun/orangepi4pro-linux (checked 2026-11-17)

[TumRedSun/orangepi4pro-linux](https://github.com/TumRedSun/orangepi4pro-linux) is the apercel author's backup of a mainline port for the **Orange Pi 4 Pro**. It was published as three commits on 2026-11-17, and the patches are dated 2026-10-20 to 2026-11-17.

- **Base:** mainline `f47d22362` (7.3.0), 21 patches applied with `git am`, plus `configs/a733-orangepi4pro.config`. A nightly GitHub Actions job builds `Image`, the dtb and modules and publishes them as a rolling `nightly` release.
- **Provenance:** all patches are by TumRedSun, separate from the CCU and dtsi series on the mailing lists, and carry no `Signed-off-by` or lore links, so they have not been posted upstream. Patches 0015–0017 are early-boot debug hacks (UART trace markers, `head.S` cache maintenance, a `memory@40000000` fallback node).
- **In-tree patches:**
  - A733 CCU, pinctrl, thermal (THS)
  - SoC dtsi
  - SerDes combo PHY + DWC PCIe host, so NVMe works
  - GMAC-210 stmmac glue (Ethernet)
  - PCK600 power domain
  - a **GPU node**: `compatible = "allwinner,sun60i-a733-gpu", "img,img-bxm-4-64", …`, clocks `CLK_GPU0`/`CLK_BUS_GPU0`, `PD_GPU_TOP`, OPPs 300/500/600/806/1008 MHz (patch 0018)
- **Out of tree:**
  - `sunxi-drm-port/`: the vendor display stack (DE v352 → TCON TV → DW HDMI 2.0) ported to 7.3. It needs `-DCONFIG_AW_DRM_*` / `-DCONFIG_ARCH_SUN60IW2` in the Makefile because Kconfig isn't evaluated for `M=` builds, and `CONFIG_CEC_CORE=m`, `CONFIG_DRM_DISPLAY_HELPER=m`.
  - `aic-port/`: AIC8800 Wi-Fi/BT, plus a new `sunxi-wlan` helper module. BT is attached with `hciattach_opi` on ttyS1 at 1.5 Mbaud.
- **GPU status:** `CONFIG_DRM_POWERVR=m` is built, but **`powervr.ko` is disabled on the board**: its insmod froze the system ("boot #88"), and it's parked until the display works. Mesa/userspace aren't part of this repo, and the driver work lives in apercel.
- **Boot chain:**
  - vendor boot0 + U-Boot 2018.05, `booti` of `Image` from NVMe
  - the kernel command line and `/memory` live in the DTB's `/chosen`, because the script warns this vendor U-Boot "corrupts the blob" on `fdt resize`/`fdt set`
  - Gentoo/OpenRC rootfs, console on ttyS0
- **Maturity:** a single developer's working backup. It includes local paths, debug patches and prebuilt binaries. It isn't a distro-ready kernel and hasn't been posted upstream; treat it as a reference for how far mainline gets on this board.

Compared with the mailing-list series, it already has a GPU node and a board DTS for the 4 Pro, plus PCIe and GMAC drivers. It still lacks mainline display (vendor port only) and a working GPU driver.

### 7.4 rebase and Armbian `edge` (2026-11-18)

The TumRedSun series is rebased onto 7.4-rc3+ in [ijiki16/orangepi4pro-linux](https://github.com/ijiki16/orangepi4pro-linux) (branch `rebase-7.4-rc3`), and packaged as an Armbian `edge` branch in [ijiki16/build](https://github.com/ijiki16/build) (branch `sun60iw2-mainline-edge`). **The GPU stays off there:** the SD dts sets `&gpu { status = "disabled"; }`, because udev autoloads `powervr.ko` and the board hangs about 8 s into boot. See [mainline.md](mainline.md) for the status of the rest of the board.

Mainline GPU support for this core would need:
1. the CCU and dtsi series merged
2. a GPU node and an `allwinner,sun60i-a733-gpu` compatible in the binding
3. 36.56.104.183 added to `pvr_gpu_support_level()`
4. the firmware in upstream linux-firmware
5. Mesa marking the core conformant

## What orangepi-build installs per release

| Release | Result |
|---|---|
| bullseye desktop | Full stack, after the `sun60iw2_pkgdir` path fix (see [building.md](building.md#4-vendor-gpuvpuisp-packages-skipped-silently-bullseye-included)). Before that fix the bullseye image had no GPU userspace either. |
| bookworm desktop | **Nothing, not even `pvrsrvkm.ko`** (verified 2026-11-16). The module is installed inside the same `bullseye\|resolute\|trixie` block of `family_tweaks_s`, and `main.sh` fetches the vendor repo only for bullseye. `MODULES` still lists `pvrsrvkm`, so expect a failed modprobe at boot. The build also warns `vendor package dir missing` for libAWIspApi, libcedarc and gst-omx (expected). |
| trixie desktop | Kernel module only. No firmware, no libraries, Xorg on stock Mesa (llvmpipe). Chrome is still patched with `--use-gl=angle --use-angle=vulkan …`, which has no Vulkan driver to use. |
| any server image | No GPU module at all (desktop only) |

## How other A733 distributions do it

All of them use **the same blob**. Radxa's `xserver-xorg-img-bxm` (a733-trixie-test repo) and Orange Pi's `sun60iw2_packages/bullseye/xserver/xserver-xorg-img-bxm_1.21.1-2_arm64.deb` have the same SHA-256, `c8e606db1abdea40a5b97f7905ea86901b50c5fe1b76a55356ab70dde3304c3a`.

### Radxa (Cubie A7A / A7Z / A7S), official Debian 13

- Apt repos `https://radxa-repo.github.io/a733-trixie` (stable, found 2026-11-16), `a733-trixie-test` and `a733-bullseye`. There is no `a733-bookworm`. All of them carry `img-bxm-dkms` 0.1.0-3 and `xserver-xorg-img-bxm` 1.0.1.
- `task-a733-xorg` depends on `img-bxm-dkms` (0.1.0-3, the kernel module through DKMS), `xserver-xorg-img-bxm-1.21.1-2.deb`, `libssl1.1`, `libxcb-dri2-0`, `picom` and `python3`.
- `libssl1.1` 1.1.1n-0+deb11u4 is copied from Debian 11 into `radxa-repo.github.io/trixie`.

### Armbian (`~/code/build`, `config/sources/families/sun60iw2.conf`)

Covers the Orange Pi 4 Pro, Orange Pi Zero 3W, Radxa Cubie A7Z and ArmSoM Sige6 on the `vendor` 6.6 kernel. Bullseye support was removed on 2026-11-09.

- `pre_package_kernel_image__sun60iw2_gpu_module`:
  - builds `pvrsrvkm` into the linux-image package (stripped, then `depmod`)
  - removes `.SECONDARY:` from the IMG kbuild Makefiles, which GNU make ≥ 4.4 rejects
  - deletes the stale `binary_sunxi_linux_nulldrmws_release` folder
- `post_family_tweaks__sun60iw2_userspace` (switches: `SUN60IW2_GPU_USERSPACE`, `_NPU_`, `_MEDIA_`, all default `yes`):
  - unpacks the bullseye `xserver-xorg-img-bxm` with `dpkg-deb -x` on **every release** and moves its `lib/` into `usr/lib/`
  - headless, GNOME and KDE images get the libraries and firmware only, with no Xorg
  - X11 desktops (xfce etc.) also get the patched Xorg, plus `apt-mark hold xserver-xorg-core`
  - for those, only `libcrypto.so.1.1` is taken from Debian 11's `libssl1.1_1.1.1w-0+deb11u8` (checksum verified) and put in a private `/usr/lib/sun60iw2-xorg-compat` folder, listed in `zz-sun60iw2-xorg-compat.conf`
  - writes the ICD files itself (`pvr.icd` → `/usr/lib/libPVROCL.so.1`) and installs `clinfo` and `vulkan-tools`
  - on trixie and later it sets `GSK_RENDERER=cairo`
- Boards marked `HAS_VIDEO_OUTPUT="no"`: Zero 3W and Cubie A7Z

The `sun60iw2-mainline-edge` branch of [ijiki16/build](https://github.com/ijiki16/build) adds an `edge` kernel for the 4 Pro. It skips all of this GPU userspace.

This is the most complete recipe for bookworm and trixie. Porting `post_family_tweaks__sun60iw2_userspace` into orangepi-build's `family_tweaks_s` would give trixie the GPU.

### Community projects

| Project | Board / OS | Stack | Reported |
|---|---|---|---|
| [cuihuir/radxa-a7z-debian12](https://github.com/cuihuir/radxa-a7z-debian12) | A7Z, Debian 12, **5.15** BSP | own `a733-pvr-gpu 24.2.6603887+gpu8`, patched KWin + XWayland | KWin/Plasma **Wayland on the GPU**, Vulkan, OpenCL, GLES 3.2; GLX still llvmpipe |
| [Rabs9/radxa-cubie-a7a-kernel](https://github.com/Rabs9/radxa-cubie-a7a-kernel) | A7A, Debian 13, 6.6.98 | vendor | GLES 3.2 (glmark2-es2 889) after an R/B colour fix; desktop uses `AccelMethod "none"` because glamor leaves cursor trails |
| [ayiejosh/a733-powervr-fex](https://github.com/ayiejosh/a733-powervr-fex) | A7A/A7S, Debian 13, 6.6-aw2511 | vendor + DRM-PRIME patch + patched Mesa (zink) | Vulkan 1.3.277, DXVK; **a GPU-composited desktop deadlocks the kernel** (power-cycle needed); GPU 600→1104 MHz via DT overlay |
| [davidhfrankelcodes/orangepizero3w-armbian-gpu-bring-up](https://github.com/davidhfrankelcodes/orangepizero3w-armbian-gpu-bring-up) | Zero 3W, Armbian resolute, 6.6.98 | vendor (Radxa test repo) | Vulkan, OpenCL 3.0 (clpeak about 19 GFLOPS), off-screen zink; GPU stuck at 600 MHz (no `clk_rate` in DTS) |
| [Haidegger22/orangepi-zero3w-gpu-npu-vpu-debian13](https://github.com/Haidegger22/orangepi-zero3w-gpu-npu-vpu-debian13) | Zero 3W, content says **Debian 11** | vendor libs copied from `radxa/allwinner-target` | load `pvrsrvkm` late (an early udev autoload panicked); libs in `/usr/local/lib` |
| [CheezeCS/apercel](https://github.com/CheezeCS/apercel), [armbian-a733-gpu](https://github.com/CheezeCS/armbian-a733-gpu) | **Orange Pi 4 Pro** (live) + Zero 3W, Armbian trixie, 6.6.98 BSP | **open**: apercel DRM driver + Mesa 26.3 + open firmware `rogue_36.56.104.183_v1.fw` (the vendor `rgx.fw` fails with "Unsupported fw info version 2") | Vulkan 1.3, GL 3.2 / GLES 3.1 via zink, sway on the GPU, Electron WebGL2; X11/xfce untested; experimental |
| [TumRedSun/orangepi4pro-linux](https://github.com/TumRedSun/orangepi4pro-linux) | **Orange Pi 4 Pro**, Gentoo, **mainline 7.3** + 21 patches | `CONFIG_DRM_POWERVR=m` with the GPU DT node from patch 0018; display via an out-of-tree vendor sunxi-drm port | NVMe/PCIe, GMAC, HDMI (vendor port), AIC8800 Wi-Fi/BT working; **`powervr.ko` insmod froze the board, so the GPU is disabled** (2026-11-17) |
| [ijiki16/orangepi4pro-linux](https://github.com/ijiki16/orangepi4pro-linux) | **Orange Pi 4 Pro**, Armbian trixie `edge`, **mainline 7.4-rc3+** + 35 patches | GPU node disabled | Tested here: SD, Ethernet at 100 Mb/s, AXP318W PMIC. No HDMI, Wi-Fi/BT or GPU ([mainline.md](mainline.md)) |
| [radxa-build/radxa-a733#40](https://github.com/radxa-build/radxa-a733/issues/40) | A7A, Radxa test repo | vendor | open issue: containers fall back to llvmpipe, `DRM_IOCTL_MODE_CREATE_DUMB` denied |

Recurring themes:
- Vulkan, OpenCL and off-screen GLES work on the vendor stack.
- A GPU-composited desktop on the 6.6 vendor kernel is unreliable: one project reports a deadlock, another cursor trails. Only the 5.15 kernel with a patched KWin reports a working accelerated desktop.
- GPU clocks often sit at 600 MHz unless a DT overlay or governor raises them.
- Don't mix firmware: the vendor stack uses `rgx.fw.*`, apercel uses `rogue_*_v1.fw`.

### Other A733 boards

| Board | Software / GPU status |
|---|---|
| Orange Pi Zero 3W, Zero 4 | Same orangepi-build family. No GPU reports found for the Zero 4. |
| Radxa Cubie A7A / A7Z / A7S | Official images (Debian 11 KDE, then Debian 13); GPU through the Radxa repo |
| ArmSoM Sige6 | Official Debian 11 from ArmSoM's own SDK (5.15 default). Armbian support merged 2026-11-10 ([PR #11276](https://github.com/armbian/build/pull/11276)): trixie xfce on vendor 6.6; the owner reports GLES 3.2 and Vulkan 1.3.277 enumeration, full desktop untested. |
| Banana Pi BPI-M8 (M8A eMMC, M8B SPI-NOR) | At launch (Nov 2026): "no OS images and no source code"; no Armbian support; GPU known only from the spec sheet |

## Checks on a running board

```bash
lsmod | grep pvrsrvkm; dmesg | grep -iE 'pvr|rgx|36\.56\.104\.183'
ls -l /dev/dri/                         # card0 = display, renderD128 = GPU
cat /sys/class/devfreq/1800000.gpu/{cur_freq,available_frequencies,governor}
vulkaninfo --summary                    # expect "PowerVR B-Series BXM-4-64 MC1", 1.3.277
clinfo | grep -E 'Platform Name|Device Name'
glmark2-es2 --off-screen                # bullseye ships glmark2-es2-x11
grep -E 'glamor|PVR|EGL' /var/log/Xorg.0.log
```

## Sources

- Radxa repos: <https://radxa-repo.github.io/a733-trixie-test>, <https://radxa-repo.github.io/trixie/files.list>
- Radxa docs: <https://docs.radxa.com/en/cubie/a7a>
- Radxa forum: <https://forum.radxa.com/t/software-issues-with-radxa-cubie-a7a/31414>
- Armbian forum: <https://forum.armbian.com/topic/56130-radxa-cubie-a7aa7z-allwinner-a733/page/7/>
- Armbian Zero 3W page: <https://armbian.com/boards/orangepizero3w>
- Armbian PR #11276: <https://github.com/armbian/build/pull/11276>
- ArmSoM docs: <https://docs.armsom.org/>
- It's FOSS, Sige6: <https://itsfoss.com/news/armsom-sige6-launched-with-allwinner-soc/>
- Banana Pi forum, BPI-M8: <https://forum.banana-pi.org/t/banana-pi-bpi-m8-sbc-design-with-allwinner-a733-chip/28004>
- soth.pl, BPI-M8: <https://en.soth.pl/news/banana-pi-bpi-m8-allwinner-a733>
- Kernel docs, drm/imagination: <https://docs.kernel.org/gpu/imagination/index.html>
- Community projects: the links in the tables above
