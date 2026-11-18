#!/usr/bin/env bash
# Read-only health check for an Orange Pi 4 Pro running the mainline (7.4 edge) kernel.
# Run on the board: sudo bash check-mainline-board.sh
# Exit status: 0 = no FAIL line, 1 = at least one FAIL, 2 = not run as root.
[[ $EUID -eq 0 ]] || { echo "run as root (reads debugfs)"; exit 2; }

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
info() { echo "INFO  $1"; }
expect() { # expect <label> <actual> <wanted>
	if [[ "$2" == "$3" ]]; then pass "$1 = $2"; else fail "$1 = ${2:-missing} (want $3)"; fi
}

mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
clk() { cat "/sys/kernel/debug/clk/$1/clk_rate" 2> /dev/null; }

info "kernel $(uname -r)"
[[ "$(uname -r)" == 7.* ]] && pass "mainline kernel" || fail "not a 7.x kernel (vendor kernel booted?)"

# Clock tree: wrong values here mean the board is not using the 26 MHz dcxo input.
expect "dcxo rate" "$(clk dcxo)" 26000000
expect "pll-ref rate" "$(clk pll-ref)" 24000000
expect "pll-peri0 rate" "$(clk pll-peri0)" 2400000000
expect "gmac0-phy rate" "$(clk gmac0-phy)" 25000000

# PMIC and the two rails Linux depends on.
[[ -e /sys/bus/i2c/drivers/axp20x-i2c/0-0036 ]] && pass "AXP318W bound at 0-0036" || fail "AXP318W driver not bound"
rails="$(cat /sys/class/regulator/regulator.*/name 2> /dev/null)"
for rail in vcc-3v3-phy vcc-3v3-sd; do
	grep -qx "$rail" <<< "$rails" && pass "regulator $rail" || fail "regulator $rail missing"
done

# Device tree facts that hang the board when wrong.
dt=/sys/firmware/devicetree/base
[[ -d $dt/reserved-memory/bl31@48000000 ]] && pass "BL31 reserved" || fail "BL31 not reserved"
gpu_status="$(tr -d '\0' < "$dt/soc/gpu@1800000/status" 2> /dev/null)"
expect "GPU node status" "$gpu_status" disabled

# Ethernet. The interface name differs between images (eth0 or end0).
netdev="$(ls /sys/bus/platform/devices/4500000.ethernet/net 2> /dev/null | head -1)"
if [[ -z "$netdev" ]]; then
	fail "GMAC has no network interface"
else
	phy="$(basename "$(readlink "/sys/class/net/$netdev/phydev/driver" 2> /dev/null)")"
	expect "$netdev PHY driver" "$phy" "YT8531 Gigabit Ethernet"
	expect "$netdev carrier" "$(cat "/sys/class/net/$netdev/carrier" 2> /dev/null)" 1
	info "$netdev speed $(cat "/sys/class/net/$netdev/speed" 2> /dev/null) Mb/s (limited by the link partner)"
	addr="$(ip -4 -o addr show "$netdev" | awk '{print $4; exit}')"
	[[ -n "$addr" ]] && pass "$netdev IPv4 $addr" || fail "$netdev has no IPv4 address"
	gw="$(ip -4 route show default | awk '{print $3; exit}')"
	if [[ -n "$gw" ]] && ping -c2 -W2 "$gw" > /dev/null 2>&1; then pass "gateway $gw answers"; else fail "gateway ${gw:-missing} does not answer"; fi
fi

# SD card health.
ios=/sys/kernel/debug/mmc2/ios
[[ -r $ios ]] && info "SD $(grep 'actual clock' "$ios" | tr -s '\t ' ' ')"
sd_errors="$(dmesg | grep -ciE 'mmc2.*(error|timeout|crc)|mmcblk2.*error|I/O error')"
expect "SD error lines in dmesg" "$sd_errors" 0

state="$(systemctl is-system-running 2> /dev/null)"
expect "systemd state" "$state" running
[[ "$state" == running ]] || systemctl --failed --no-legend --plain | sed 's/^/INFO  failed unit: /'

echo "RESULT $fails failure(s)"
[[ $fails -eq 0 ]]
