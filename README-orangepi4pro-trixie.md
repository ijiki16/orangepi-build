# Orange Pi 4 Pro — Debian 13 (trixie) image build notes

How `orangepi-build` produces the Debian 13 image for the Orange Pi 4 Pro: boot chain, kernel, config, drivers and rootfs.
Based on `orangepi-build` branch `next` (upstream HEAD `a95129b`, 2026-09-11) and kernel `orange-pi-6.6-sun60iw2` (`2ac08e8c7`, 2026-09-17).

See also:
- [docs/a733/building.md](docs/a733/building.md): building in Docker on unsupported hosts, plus the build failures and their fixes. This includes the vendor package path bug, which also affected bullseye.
- [docs/a733/gpu.md](docs/a733/gpu.md): the GPU stack, status per release, and how Radxa, Armbian and other A733 boards handle the GPU.
- [docs/a733/mainline.md](docs/a733/mainline.md): the mainline 7.4 port (Armbian `edge`): status, build steps, board facts and bring-up fixes.

## Known problem: trixie desktop is missing the GPU/VPU/ISP userspace

- `scripts/main.sh:536` fetches the vendor blob repo `sun60iw2_packages` **only when `RELEASE=bullseye`**.
- The public repos (GitHub `orangepi-xunlong/rk-rootfs-build@sun60iw2_packages`, Gitee `orangepi-xunlong/sun60iw2_packages`, last update 2026-01-23) contain only `bullseye/` and `npu/`.
- `family_tweaks_s` for trixie expects `sun60iw2_packages/{libcedarc,libAWIspApi,gst-omx-generic1.0}` plus `xserver_trixie/` and `vlc_trixie/` — none exist.
- `dpkg_install_debs_chroot` returns silently on a missing directory (`scripts/image-helpers.sh:254`); the xserver `cp`/`dpkg -i` errors only go to `install.log`.
- Result: `pvrsrvkm.ko` is installed but no matching PowerVR userspace (EGL/GLES/Vulkan/OpenCL), no Cedar hardware video decode and no camera ISP library. Chrome is still patched for ANGLE/Vulkan, which can't work.
- The bullseye build gets the full stack. Official prebuilt trixie images probably use an internal repo (assumption).

Fix: provide the `.deb`s yourself (the bullseye ones are DDK 24.2.6603887), laid out the way `family_tweaks_s` expects.

## Build command

```
./build.sh BOARD=orangepi4pro BRANCH=current RELEASE=trixie BUILD_OPT=image \
           BUILD_DESKTOP=yes|no KERNEL_CONFIGURE=no
```

| File | What it sets |
|---|---|
| `external/config/boards/orangepi4pro.conf` | family `sun60iw2`, U-Boot defconfig `sun60iw2p1_t736_defconfig`, DTB `allwinner/sun60i-a733-orangepi-4-pro.dtb`, modules loaded at boot `aic8800_fdrv aic8800_btlpm pvrsrvkm`. Trixie only on `current`. |
| `external/config/sources/families/sun60iw2.conf` | kernel source/branch, overlay prefix `sun60i-a733`, CPU 416 MHz–2.0 GHz `ondemand`, `OFFSET=32`, boot-loader packing, trixie package steps |
| `external/config/sources/families/include/sunxi64_common.inc` | `write_uboot_platform` (how the boot loader is written to the card) |

## Hardware

- **SoC:** Allwinner A733 (sun60iw2p1), 2× Cortex-A76 + 6× Cortex-A55 (`NR_CPUS=8`). The "quad core" comment in the board config is wrong.
- **RAM:** LPDDR4/LPDDR5 (test board: 12 GB LPDDR5 @ 1800 MHz).
- **GPU:** Imagination BXM (`AW_GPU_TYPE="bxm"`), DDK 24.2.6603887.
- **NPU:** VeriSilicon VIP (`AW_NNA_VIP=m`).
- **PMIC:** AXP8191 in the vendor BSP (main; the schematic and the mainline driver call it AXP318W) + AXP515 (charger).

## Boot chain

| Step | Component | Notes |
|---|---|---|
| 1 | `boot0_sdcard_a733.fex` (blob) | First stage, DRAM init. Written at 8 KiB. |
| 2 | `boot_package.fex` = u-boot + monitor (TF-A BL31 v2.5, blob) + scp (arisc firmware, blob) | Written at 16.4 MB (8k × 2050). OP-TEE commented out. |
| 3 | U-Boot **v2018.05** BSP (`u-boot/v2018.05-sun60iw2`) | Built **32-bit** with `arm-linux-gnueabi-` (GCC > 6). `uboot_custom_postprocess` builds the U-Boot DTB from `external/packages/pack-uboot/sun60iw2/bin/dts`, merges `sys_config.fex`, packs with `dragonsecboot`. |
| 4 | `/boot/boot.scr` ← `external/config/bootscripts/boot-sun60iw2.cmd` | Loads `uImage` + `uInitrd` + DTB, applies `dtb/allwinner/overlay/sun60i-a733-<name>.dtbo` and `overlay-user/*.dtbo`, boots with `bootm`. Settings in `/boot/orangepiEnv.txt`. |

- **Kernel command line:** `root=PARTUUID=… rootwait console=ttyS0,115200 console=tty1 earlyprintk=sunxi-uart,0x02500000 clk_ignore_unused swiotlb=65536` + Docker cgroup flags.
- **Image layout:** one ext4 partition starting at 32 MiB, `/boot` inside it.
- **Other install targets:** SPI-NOR (`write_uboot_platform_mtd`), UFS (`write_uboot_platform_ufs`).

## Kernel

- **Source:** `orangepi-xunlong/linux-orangepi`, branch `orange-pi-6.6-sun60iw2`, **6.6.98** — Allwinner "aiot-linux v1.5.0" BSP, vendor drivers in `bsp/drivers/*`.
- **Config:** `external/config/kernel/linux-sun60iw2-current-a733.config` (1683 `=y`, 326 `=m`):
  - `PREEMPT`, `HZ_250`, 39-bit VA / 4K pages, `schedutil`
  - AppArmor + SELinux, BTRFS, ZRAM (zstd), OverlayFS, NVMe built in
  - `DEBUG_INFO=y` → large `-dbg` package
- **Toolchain:** GCC > 10 → `gcc-arm-11.2 aarch64-none-linux-gnu`.
- **GPU module:** built out of tree from `bsp/modules/gpu/img-bxm/.../rogue_km` (`scripts/compilation.sh:528`), installed to `/lib/modules/*/extra` on desktop builds only.
- **Packages:** `linux-image-current-sun60iw2`, `linux-dtb-current-sun60iw2`, `linux-headers-current-sun60iw2`.

## Drivers by hardware block

| Block | DTS node | Driver / config |
|---|---|---|
| Display | `de`, `hdmi0`, `dsi1`, eDP, LVDS | `AW_DRM*` (vendor DRM), HDMI 2.0 via `AW_DRM_HDMI20` |
| GPU | `gpu` | `pvrsrvkm` (out of tree) |
| Video enc/dec | VE | `AW_VIDEO_ENCODER_DECODER=m`; userspace libcedarc, gst-omx |
| Camera | `vind0`, MIPI CSI | `AW_VIDEO_SUNXI_VIN=m`; userspace libAWIspApi |
| NPU | `npu` | `AW_NNA_VIP=m`; userspace `npu/usr/lib/libVIPhal.so`, demos `/opt/vpm_run`, `/opt/yolov5` |
| Ethernet | `gmac0`, RGMII, tx-delay 12 / rx-delay 10 | `AW_STMMAC_ETH=m`, `MOTORCOMM_PHY=m` |
| WiFi/BT | `sdc1` SDIO, `rfkill`, `btlpm` | AIC8800 (`bsp/drivers/net/wireless/aic8800`) |
| Storage | `sdc0` SD, `sdc2` eMMC, `ufs`, `pcie_rc` Gen3 (M.2 NVMe), `spi0` NOR | `AW_MMC`, `AW_UFS`, `AW_PCIE_RC` + `AW_CADENCE_COMBOPHY`, `AW_MTD_SPI_NOR_6_1` |
| USB | usbc0 OTG, usbc1 EHCI/OHCI, usbc2 xHCI | DWC3 / xHCI, Type-C HUSB311 |
| Audio | ES8388 (twi7), AC101, HDMI audio, I2S0–4, S/PDIF (OWA) | `SND_SOC_ES8323`, `SND_SOC_AC101`, `SND_SOC_SUNXI_*` |
| Other | RTC HYM8563 (s_twi2), Goodix GT9271 touch (twi5), IR RX, LEDC, GPADC, thermal, AXP regulators | |
| Overlays | | i2c0–3, pwm0–9, spi3-cs0-cs1-spidev, uart2/6/7/8, lcd |

## Rootfs steps for trixie

- **debootstrap tweaks:** `rc.local`, `os-release` version fix, no `software-properties-common` (`scripts/distributions.sh:777`, `scripts/general.sh:1980`).
- **`family_tweaks_s`:**
  - rsync `external/packages/bsp/overlays_arm64` and `external/packages/bsp/sun60iw2` (adbd, `check_temp.sh`, memtester, stressapptest, `ld.so.conf.d/00-pvr-priority.conf`, OpenCL `pvr.icd`, Vulkan `img_icd.json` → `/lib/libVK_IMG.so`)
  - NPU blobs, bluez, lirc, v4l-utils, libopencv
- **Desktop only:**
  - gstreamer, vulkan-tools, clinfo; `GSK_RENDERER=cairo`
  - meant to install `xserver-xorg-img-bxm` (patched Xorg + PVR Mesa/EGL/GLES/Vulkan/OpenCL), VLC, Chrome — see the known problem above
  - audio-card detection service, wiringOP

## Boot log notes (Armbian-unofficial trixie, vendor 6.6.98)

Harmless errors seen on a working boot:
- UFS PHY timeout — no UFS module fitted.
- AXP515 probe fail — no battery.
- `reserving fdt memory region failed` at `0x48000000` — BL31 area.
- No HDMI framebuffer in U-Boot — nothing connected.
