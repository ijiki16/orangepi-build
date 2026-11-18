# Mainline Linux on the Orange Pi 4 Pro (A733)

The state of the mainline 7.4 port as of 2026-11-18: what works, how to build it, the board facts behind it, and how each bring-up failure was fixed.

Everything here applies to the **mainline kernel only**. The vendor 6.6 kernel that `orangepi-build` ships is covered in [building.md](building.md) and [gpu.md](gpu.md).

## Status

Tested on one Orange Pi 4 Pro (12 GB) running Armbian trixie `edge` from a 64 GB SD card.

| Function | Status |
|---|---|
| Boot from SD through the vendor boot0 and U-Boot | Works |
| Serial console (ttyS0, 115200) | Works |
| NVMe (PCIe) | Detected; not used as rootfs in this setup |
| Ethernet | Works at 100 Mb/s: DHCP, ping, DNS, SSH. **Gigabit is untested** (the switch offers 10/100 only) |
| PMIC (AXP318W) | Works: the kernel powers the Ethernet PHY and SD card |
| Clock rates | Correct: `pll-ref` 24 MHz, `pll-peri0` 2.4 GHz |
| HDMI | **Not working.** `sunxi-drm-port` does not build on 7.4 |
| Wi-Fi and Bluetooth | **Not working.** The AIC8800 modules are not ported |
| GPU | **Disabled.** `powervr.ko` hangs the board on probe |
| SD UHS speeds | Not available. The switchable SD I/O rail (vqmmc) is not described, so SD runs at 3.3 V, 50 MHz |

The kernel packages were tested by installing them on a running board. The final `.img` built from the same tree has **not** been boot-tested from a fresh flash.

## Where the code is

| Repo | Branch | Contents |
|---|---|---|
| [ijiki16/orangepi4pro-linux](https://github.com/ijiki16/orangepi4pro-linux) | `rebase-7.4-rc3` | 35 patches on torvalds `666539eecdf4` (7.4-rc3+) in `kernel/patches/` |
| [ijiki16/build](https://github.com/ijiki16/build) | `sun60iw2-mainline-edge` | Armbian `edge` branch: the 35 patches plus one Armbian-only dts patch |
| `~/code/linux-a733` (local) | `a733-rebased` | The kernel tree the patches are exported from |

## Building

Build the Armbian image from a checkout of `sun60iw2-mainline-edge`:

```bash
./compile.sh build BOARD=orangepi4pro BRANCH=edge RELEASE=trixie \
  BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no COMPRESS_OUTPUTIMAGE=sha,img
```

The image is written to `output/images/`, and the kernel packages to `output/debs/`.

To update a running board and keep its setup, copy `linux-image-edge-sun60iw2_*.deb` and `linux-dtb-edge-sun60iw2_*.deb` to it, then:

```bash
sudo dpkg -i linux-image-edge-sun60iw2_*.deb linux-dtb-edge-sun60iw2_*.deb
sudo reboot
```

Back up `/boot` and `/lib/modules/<version>` first: the new packages replace files of the same version.

To build only the kernel:

```bash
git am /path/to/orangepi4pro-linux/kernel/patches/*.patch   # on 666539eecdf4
cp /path/to/orangepi4pro-linux/configs/a733-orangepi4pro.config .config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs modules
```

## Automated kernel test

`opi-test.sh` builds the committed kernel, installs it on the board over SSH, reboots and runs the health check:

```bash
S=.claude/skills/orangepi-a733-image-build
bash $S/opi-test.sh setup    # once: create the SSH key, then run the ssh-copy-id command it prints
bash $S/opi-test.sh kernel   # build + deploy + check
```

- The script finds the board by scanning the LAN, because the MAC address and IP change on every boot.
- Each run saves its logs in `~/code/orangepi4pro-sd/runs/`.
- The previous kernel is kept on the board in `/root/opi-test/last`.
- If the board does not return within 5 minutes, the script stops. Power-cycle the board by hand.

| Exit status | Meaning |
|---|---|
| 0 | New kernel running, all checks passed |
| 1 | A health check failed, or a different kernel is running |
| 2 | Usage or setup problem |
| 3 | The board did not come back |
| 4 | The build failed |

## Serial logs per boot

`uart-boots.py` saves the serial console as readable text, with one file per boot and a new part every 5 MB:

```bash
setsid nohup python3 -I .claude/skills/orangepi-a733-image-build/uart-boots.py --dir ~/uart-boots > /dev/null 2>&1 &
tail -f ~/uart-boots/latest.log
```

Only one program can read the serial port reliably. `opi-test.sh` leaves the port alone while the logger runs.

## Checking a running board

Copy the script to the board and run it there. It only reads state:

```bash
sudo bash .claude/skills/orangepi-a733-image-build/check-mainline-board.sh
```

Every line must say `PASS` or `INFO`. The exit status is 1 if any line says `FAIL`.

## Boot chain

boot0 (8 KiB) → `boot_package` (16400 KiB: vendor U-Boot 2018, BL31, SCP) → `boot.scr` → `booti` → Linux.

| Address | Use |
|---|---|
| `0x41000000` | Kernel `Image` (61 MB with Armbian's BTF) |
| `0x48000000`–`0x48ffffff` | **BL31 secure monitor.** Nothing may be loaded here |
| `0x4a000000` | DTB |
| `0x4b000000` | `uInitrd` (34 MB) |
| `0x4d000000` | Scratch area for `armbianEnv.txt`, used before the initrd loads |

Rules for a boot script on this U-Boot:

- Set `fdt_high` and `initrd_high` to `0xffffffff`. Otherwise U-Boot moves the initrd down onto BL31.
- Build the DTB with free space (`DTC_FLAGS_<dtb> := -p 16384`). U-Boot writes `bootargs` and the initrd range into `/chosen`, and hangs if there is no room.
- U-Boot does pass a non-empty `bootargs` to the kernel. `/proc/cmdline` on the Armbian image shows the script's `root=UUID=…`. The DTB's `/chosen` command line is used only when the script leaves `bootargs` empty.

## Board facts

| Fact | Value | Evidence |
|---|---|---|
| Crystal (DCXO) | **26 MHz** | RTC `DCXO_CTRL` (`0x07090160`) bits 15:14 read 2 |
| PMIC | AXP318W at I2C `0x36` on S-TWI0 (PL0/PL1, function 2). The vendor BSP calls it AXP8191 | Schematic v1.3.2; the `x-powers,axp318w` driver binds and drives it |
| Ethernet PHY supply | PMIC `SWOUT1` (`dc1sw1`), reg `0x11` bit 3. **boot0 leaves it off** | Register read: `0x11` = `0x17` |
| SD card supply | PMIC `SWOUT2` (`dc1sw2`), reg `0x11` bit 4 | Same register read |
| Ethernet PHY | Motorcomm YT8531C, MDIO address 1, ID `4f51e91b` | MII register read |
| PHY reset | **PH16**, through a level shifter. The A733 has no port A, so the board dts's PA14 cannot work | Schematic p.19 and A733 pinout |
| MDC clock | The CSR clock is the 200 MHz AHB, so `snps,clk-csr = <4>` | Vendor driver (`clk_csr = 4`) |
| GMAC TX clock | From the PHY's `CLK_OUT` at 125 MHz into PH3 (`RGMII0-CLKIN`) | Schematic p.19; DMA reset fails without it |
| PHY delay registers | Ext `0xA001` = `0x8120`, `0xA003` = `0x00f1` | Read under the vendor kernel; mainline now matches |
| Debug UART | UART0 is already muxed by boot0. PF2/PF4 are SD lines, so Linux must not claim them | Pinout and boot log |

**Open question:** the schematic shows a 25 MHz crystal on the PHY and marks the SoC clock path as not fitted, but the vendor dts sets `aw,soc-phy-clk-en`. The glue driver enables the SoC's `gmac0-phy` clock as the vendor does. Nobody has tested whether this board needs that clock.

## Bring-up failures and fixes

In the order they appear on a new port.

| Symptom | Cause | Fix |
|---|---|---|
| `pin PF2 already requested by 2500000.serial` | The dtsi muxes UART0 onto SD pins | Delete `pinctrl-0` from `&uart0` |
| RCU stall or soft lockup on CPU0 just after mmc0 probes | Interrupts from the card-detect pin PF6. The exact cause was not isolated | `broken-cd` |
| `no support for card's volts` | mmc0 has no `vmmc-supply` | Use PMIC `SWOUT2` |
| Hard hang about 8 s into boot | udev autoloads `powervr.ko` | Set `&gpu { status = "disabled"; }` |
| `MDIO device at address 1 is missing` | Three causes together: the glue register is lost, the PHY has no power, and the MDC is too fast | The next three rows |
| Glue register `0x04508000` reads `0x8000`, MAC says `GMII/MII` | The glue wrote it while the GMAC was in reset | Release the bus reset and clock first. Bind `stmmaceth` to the AXI reset and `ahb` to the bus reset |
| MDIO reads `ffff` at every divider | `SWOUT1` is off | AXP318W driver and `phy-supply` |
| MDC at 12.5 MHz | stmmac derives it from the 24 MHz gate | `snps,clk-csr = <4>` |
| `setup of GPIO reset failed: -517`, endless retries | PHY reset points at PA14, which does not exist | `reset-gpios` on PH16 |
| `no phy found` although YT8531 bound | `gmac0` has no `phy-handle` | Add `phy-handle` |
| `Failed to reset the dma` | The driver disables the PHY's clock output by default | `motorcomm,clk-out-frequency-hz = <125000000>` |
| Link up, TX counts rise, RX stays near 0, no DHCP | `phy-mode = "rgmii"` clears the RXC delay | `rgmii-id` with `rx-internal-delay-ps = <1900>`, `tx-internal-delay-ps = <150>` |
| U-Boot: `could not set bootargs FDT_ERR_NOSPACE` | The DTB has no free space | Pad the DTB |
| Silence after `Starting kernel ...`, initrd moved to about `0x47e10000` | The initrd overwrote BL31 | `fdt_high`, `initrd_high`, and reserve BL31 in the dtsi |
| `pll-ref` reads 22.15 MHz | The PLL input was modelled as 24 MHz | Feed `pll-ref` from a `dcxo` clock set to 26 MHz |

Do not set `osc24M` to 26 MHz. The module clock source named `osc24M` is `SYS_CLK24M`, which stays at 24 MHz (A733 manual, `SMHC0_CLK_REG`). Only `pll-ref` and the RTC's `hosc` input use the crystal.

## Debugging methods

**Compare with the vendor kernel.** The vendor 6.6 kernel has working hardware, so dump the same registers under both kernels and diff them. This found the glue register, the PHY clock and the delay bits.

| Block | Base address | Useful offsets |
|---|---|---|
| CCU | `0x02002000` | `0x1410` GMAC0 PHY clock, `0x141c` GMAC0 bus gate and resets |
| PIO | `0x02000000` | `0x40` power mode; bank PH at `0x400` (mux), `0x420` (drive), `0x430` (pull) |
| GMAC | `0x04500000` | `0x200` MDIO address, `0x204` MDIO data |
| GMAC glue | `0x04508000` | `0x00` syscfg |
| RTC | `0x07090000` | `0x160` `DCXO_CTRL` |

GMAC registers read `0xffff` while the interface is down, because its clocks are off.

**Scripted serial console:**
- systemd and login send `ESC[6n` terminal-size queries. A script must answer each with a cursor report such as `ESC[50;160R`, or the login stalls and restarts.
- A `sudo` password prompt consumes the next typed lines. Pipe the password with `sudo -S -p ''`.
- Send files as base64 inside a heredoc after `stty -echo`, then compare checksums.

**Probe-retry floods.** A deferred probe that retries forever can make the serial console unusable. Power-cycle the board to recover.

## Comparison with armbian/build PR #10712

[PR #10712](https://github.com/armbian/build/pull/10712) (`deece`) is a larger port of this board. On 2026-11-18 it was an open draft with changes requested by a maintainer and merge conflicts.

| | PR #10712 | This port |
|---|---|---|
| Kernel | 7.2.7 + 56 patches | 7.4-rc3+ + 35 patches |
| Boot chain | Mainline U-Boot v2026.07 and TF-A | Vendor boot0, U-Boot 2018 and BL31 |
| Reported working | Gigabit Ethernet, Wi-Fi/BT, USB3, HDMI through simplefb, NPU, SPI-NOR | SD, NVMe detection, Ethernet at 100 Mb/s, PMIC |

The AXP318W patches here (0029–0033) come from that PR's patch set. Its board dts uses the compatible `x-powers,axp8191`, which has no kernel driver in the PR. This port uses `x-powers,axp318w`.

Both ports add an `edge` branch for `orangepi4pro` with the same file names, so they conflict.

## Open work

- Boot-test a fresh flash of the final image.
- Test gigabit Ethernet.
- Move the Ethernet, SD and PMIC fixes from the SD dts into the board dts. The NVMe board dts still has the PA14 reset and no PMIC node.
- Describe the SD I/O rail (vqmmc) to enable UHS speeds.
- Port `sunxi-drm-port` to 7.4 for HDMI, and rebuild the AIC8800 modules for Wi-Fi and Bluetooth.
- Remove the early-boot debug patches (0015–0017) from the series.
