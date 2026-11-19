#!/usr/bin/env bash
# Build the mainline (edge) kernel, install it on an Orange Pi 4 Pro over SSH, reboot and check it.
#
#   opi-test.sh setup            create the SSH key and print the one command that authorizes it
#   opi-test.sh build            export the patches and build the kernel packages
#   opi-test.sh deploy           install the newest build on the board, reboot, run the checks
#   opi-test.sh check            run the health check on the running board
#   opi-test.sh kernel           build + deploy
#   opi-test.sh rollback         on an A/B board: make the previous good kernel the good one, reboot
#
# On a board with A/B slots (ab-boot/ in the orangepi4pro-linux repo, the opi-slot tool), deploy
# installs the kernel as a trial slot: a kernel that fails to boot falls back to the good one,
# so no reflash is needed. Other boards get the kernel through dpkg.
#
# Exit status: 0 pass, 1 health check failed, 2 usage or setup problem, 3 board did not come back,
# 4 build failed.
#
# Settings (environment): LINUX_TREE, ARMBIAN_TREE, RUNS_DIR, OPI_HOSTNAME, BOOT_TIMEOUT.
set -uo pipefail

LINUX_TREE="${LINUX_TREE:-$HOME/code/linux-a733}"
ARMBIAN_TREE="${ARMBIAN_TREE:-$HOME/code/build}"
RUNS_DIR="${RUNS_DIR:-$HOME/code/orangepi4pro-sd/runs}"
OPI_HOSTNAME="${OPI_HOSTNAME:-orangepi4pro}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
KERNEL_BASE="666539eecdf4"
PATCH_DIR="patch/kernel/archive/sun60iw2-7.4"
KEY="$HOME/.ssh/opi4pro_test"
STATE_DIR="$HOME/.config/opi4pro-test"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

say() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die() { # die <exit status> <message>
	say "ERROR: $2"
	exit "$1"
}
board() { ssh "${SSH_OPTS[@]}" "root@$BOARD_IP" "$@"; }

is_board() { # is_board <ip>: true when the test key logs in and the hostname matches
	[[ "$(ssh "${SSH_OPTS[@]}" "root@$1" hostname 2> /dev/null)" == "$OPI_HOSTNAME" ]]
}

find_board() { # Sets BOARD_IP. The MAC address, and so the IP, changes on every boot.
	local ip prefix candidate
	local -a pings=()
	ip="$(cat "$STATE_DIR/ip" 2> /dev/null)"
	if [[ -n "$ip" ]] && is_board "$ip"; then
		BOARD_IP="$ip"
		return 0
	fi
	prefix="$(ip -4 route show default | awk '{print $3; exit}' | cut -d. -f1-3)"
	[[ -n "$prefix" ]] || return 1
	for ip in $(seq 1 254); do
		ping -c1 -W1 "$prefix.$ip" > /dev/null 2>&1 &
		pings+=($!)
	done
	wait "${pings[@]}" # Not a bare wait: the serial logger also runs in the background.
	for candidate in $(ip neigh | awk '/REACHABLE|STALE|DELAY/{print $1}' | grep "^$prefix\."); do
		timeout 2 bash -c "exec 3<>/dev/tcp/$candidate/22 && head -c 40 <&3" 2> /dev/null | grep -qa Debian || continue
		if is_board "$candidate"; then
			BOARD_IP="$candidate"
			mkdir -p "$STATE_DIR"
			echo "$candidate" > "$STATE_DIR/ip"
			return 0
		fi
	done
	return 1
}

need_key() {
	[[ -f "$KEY" ]] || die 2 "no SSH key. Run: $0 setup"
}

new_run() { # Sets RUN to a new directory for this run's logs.
	RUN="$RUNS_DIR/$(date +%Y%m%d-%H%M%S)-$1"
	mkdir -p "$RUN"
	say "logs: $RUN"
}

cmd_setup() {
	if [[ ! -f "$KEY" ]]; then
		mkdir -p "$HOME/.ssh"
		ssh-keygen -q -t ed25519 -N '' -C opi4pro-test -f "$KEY" || die 2 "ssh-keygen failed"
		say "created $KEY"
	fi
	say "finish Armbian's first-login setup, then authorize the key once (asks for the root password):"
	echo "    ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY.pub root@<board-ip>"
}

sync_patches() { # Copy the committed kernel series into Armbian. The Armbian-only patch stays last.
	local tmp dest extra count
	[[ -z "$(git -C "$LINUX_TREE" status --porcelain --untracked-files=no)" ]] ||
		die 2 "$LINUX_TREE has uncommitted changes. The build uses committed patches only: commit them first"
	dest="$ARMBIAN_TREE/$PATCH_DIR"
	tmp="$(mktemp -d)"
	git -C "$LINUX_TREE" format-patch -q --no-signature "$KERNEL_BASE..HEAD" -o "$tmp/series" || die 2 "format-patch failed"
	count="$(find "$tmp/series" -name '*.patch' | wc -l)"
	extra="$(find "$dest" -name '*-add-OrangePi-4-Pro-Armbian-varia.patch' | head -1)"
	[[ -n "$extra" ]] || die 2 "Armbian-only dts patch not found in $dest"
	cp "$extra" "$tmp/series/$(printf '%04d' $((count + 1)))-arm64-dts-allwinner-add-OrangePi-4-Pro-Armbian-varia.patch"
	find "$dest" -name '*.patch' -delete
	cp "$tmp"/series/*.patch "$dest"/
	rm -rf "$tmp"
	say "patches: $count kernel + 1 Armbian-only"
}

cmd_build() {
	local log summary version detail
	new_run build
	log="$RUN/build.log"
	sync_patches
	say "building the kernel (this can take 10-50 minutes)"
	(cd "$ARMBIAN_TREE" && ./compile.sh kernel BOARD=orangepi4pro BRANCH=edge RELEASE=trixie KERNEL_CONFIGURE=no) > "$log" 2>&1 ||
		die 4 "kernel build failed, see $log"
	# Armbian writes the patch summary to its own log, not to the console.
	detail="$(find "$ARMBIAN_TREE/output/logs" -maxdepth 1 -name 'log-kernel-*.log' -newer "$RUN" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)"
	summary="$(grep -ah 'kernel patching:' "$detail" 2> /dev/null | tail -1)"
	[[ -n "$summary" ]] || summary="$(grep -a 'kernel patching:' "$log" | tail -1)"
	if [[ -n "$summary" ]]; then
		say "${summary#*Summary: }"
		[[ "$summary" == *" 0 with problems"* ]] || die 4 "patches have problems, see ${detail:-$log}"
	else
		# A cached kernel skips patching, so there is no summary to read.
		say "no patch summary in this build (the kernel may come from the cache)"
	fi
	version="$(LC_ALL=C sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -aoE '[0-9]+\.[0-9]+[^ ]*-S[0-9a-f]{4}-D[0-9a-f]{4}-P[0-9a-f]{4}-[A-Za-z0-9-]+' | tail -1)"
	[[ -n "$version" ]] || die 4 "could not read the kernel version from $log"
	mkdir -p "$STATE_DIR"
	echo "$version" > "$STATE_DIR/version"
	find_debs "$version" || die 4 "no packages found for $version"
	say "built $version"
}

find_debs() { # find_debs <version>: sets IMAGE_DEB and DTB_DEB
	IMAGE_DEB="$(find "$ARMBIAN_TREE/output" -name "linux-image-edge-sun60iw2_*__$1.deb" -print -quit)"
	DTB_DEB="$(find "$ARMBIAN_TREE/output" -name "linux-dtb-edge-sun60iw2_*__$1.deb" -print -quit)"
	[[ -n "$IMAGE_DEB" && -n "$DTB_DEB" ]]
}

start_uart() { # Keep a serial log of the reboot when no other program is reading the port.
	UART_PID=""
	UART_LOG="$HOME/code/orangepi4pro-sd/uart/boots/latest.log" # written by uart-boots.py when it runs
	[[ -r /dev/ttyUSB0 ]] || return 0
	fuser -s /dev/ttyUSB0 2> /dev/null && return 0
	UART_LOG="$RUN/uart.log"
	# Keep the port open between stty and cat. Closing it can restore echo, which types the board's
	# own output back into its login prompt.
	(
		exec 3< /dev/ttyUSB0 || exit 0
		stty 115200 cs8 -cstopb -parenb raw -echo -ixon <&3 2> /dev/null || exit 0
		exec cat <&3
	) > "$RUN/uart.log" 2> /dev/null &
	UART_PID=$!
}
stop_uart() { [[ -z "${UART_PID:-}" ]] || kill "$UART_PID" 2> /dev/null; }

cmd_check() {
	local out="${RUN:-/tmp}/check.txt" status
	[[ -n "${BOARD_IP:-}" ]] || { need_key; find_board || die 3 "board not found on the network"; }
	board 'bash -s' < "$SCRIPT_DIR/check-mainline-board.sh" 2>&1 | tee "$out"
	status=${PIPESTATUS[0]}
	[[ $status -eq 0 ]] && say "PASS: board $BOARD_IP" || say "FAIL: health check failed on $BOARD_IP"
	return $((status == 0 ? 0 : 1))
}

cmd_deploy() {
	local version kver want have deadline
	need_key
	version="$(cat "$STATE_DIR/version" 2> /dev/null)"
	[[ -n "$version" ]] || die 2 "nothing built yet. Run: $0 build"
	find_debs "$version" || die 2 "packages for $version are missing. Run: $0 build"
	[[ -n "${RUN:-}" ]] || new_run deploy
	find_board || die 3 "board not found. Is it on, and did you run: $0 setup ?"
	say "board $BOARD_IP, installing $version"

	kver="$(dpkg-deb -c "$IMAGE_DEB" | grep -oE 'boot/vmlinuz-[^ ]+' | head -1 | sed 's|boot/vmlinuz-||')"
	[[ -n "$kver" ]] || die 2 "cannot read the kernel version from $IMAGE_DEB"
	want="$(dpkg-deb --fsys-tarfile "$IMAGE_DEB" 2> /dev/null | tar -xO "./boot/vmlinuz-$kver" 2> /dev/null | LC_ALL=C grep -aoE 'Linux version [^%]* #[0-9]+ [^%]*' | head -1)"
	[[ -n "$want" ]] || die 2 "cannot read the version string from the kernel image"

	board "mkdir -p /root/opi-test" || die 2 "cannot reach the board"
	if ! board 'command -v opi-slot' > /dev/null 2>&1; then
		board "rm -rf /root/opi-test/last && mkdir /root/opi-test/last &&
			cp -a /boot/vmlinuz-$kver /boot/uInitrd-$kver /boot/dtb-$kver /root/opi-test/last/" ||
			die 2 "could not back up the running kernel on the board"
	fi
	scp "${SSH_OPTS[@]}" -q "$IMAGE_DEB" "root@$BOARD_IP:/root/opi-test/linux-image.deb" || die 2 "copy failed"
	scp "${SSH_OPTS[@]}" -q "$DTB_DEB" "root@$BOARD_IP:/root/opi-test/linux-dtb.deb" || die 2 "copy failed"
	[[ "$(sha256sum < "$IMAGE_DEB")" == "$(board 'sha256sum < /root/opi-test/linux-image.deb')" ]] || die 2 "image package checksum mismatch"
	[[ "$(sha256sum < "$DTB_DEB")" == "$(board 'sha256sum < /root/opi-test/linux-dtb.deb')" ]] || die 2 "dtb package checksum mismatch"
	if board 'command -v opi-slot' > /dev/null 2>&1; then
		deploy_trial "$want"
		return
	fi
	board 'dpkg -i /root/opi-test/linux-image.deb /root/opi-test/linux-dtb.deb && sync' > "$RUN/dpkg.log" 2>&1 ||
		die 2 "dpkg failed, see $RUN/dpkg.log"

	start_uart
	say "rebooting"
	timeout 15 ssh "${SSH_OPTS[@]}" "root@$BOARD_IP" 'systemctl reboot' > /dev/null 2>&1
	deadline=$((SECONDS + 60))
	while is_board "$BOARD_IP" && ((SECONDS < deadline)); do sleep 2; done
	deadline=$((SECONDS + BOOT_TIMEOUT))
	until find_board; do
		if ((SECONDS >= deadline)); then
			stop_uart
			die 3 "board did not return within ${BOOT_TIMEOUT}s. Power-cycle it. The old kernel is in /root/opi-test/last. Serial log: $UART_LOG"
		fi
		sleep 5
	done
	stop_uart

	have="$(board 'cat /proc/version')"
	[[ "$have" == "$want"* ]] || die 1 "the board runs a different kernel: $have"
	say "running the new kernel on $BOARD_IP"
	cmd_check
}

reboot_and_wait() { # reboot_and_wait <message if the board does not return>
	start_uart
	say "rebooting"
	timeout 15 ssh "${SSH_OPTS[@]}" "root@$BOARD_IP" 'systemctl reboot' > /dev/null 2>&1
	local deadline=$((SECONDS + 60))
	while is_board "$BOARD_IP" && ((SECONDS < deadline)); do sleep 2; done
	deadline=$((SECONDS + BOOT_TIMEOUT))
	until find_board; do
		if ((SECONDS >= deadline)); then
			stop_uart
			die 3 "board did not return within ${BOOT_TIMEOUT}s. $1 Serial log: $UART_LOG"
		fi
		sleep 5
	done
	stop_uart
}

booted_slot() { board 'sed -n "s/.*opi_slot=\([a-z]*\).*/\1/p" /proc/cmdline'; }

deploy_trial() { # deploy_trial <expected /proc/version>: install as a trial slot and boot it once
	local slot result
	# opi-slot try refuses unless the board runs the good slot's root (a promoted trial counts).
	board 'opi-slot try /root/opi-test/linux-image.deb /root/opi-test/linux-dtb.deb' > "$RUN/opi-slot.log" 2>&1 ||
		die 2 "opi-slot try failed, see $RUN/opi-slot.log"
	say "$(tail -1 "$RUN/opi-slot.log")"
	reboot_and_wait "Power-cycle it: an armed trial that hangs early falls back to the good slot on the next boot."
	# The confirm service decides when the boot has reached multi-user.target.
	board 'timeout 240 sh -c "while systemctl is-active -q opi-slot-confirm || systemctl list-jobs --no-legend | grep -q opi-slot-confirm; do sleep 3; done"'
	slot="$(booted_slot)"
	result="$(board 'journalctl -b -u opi-slot-confirm -o cat --no-pager | grep "opi-slot:" | tail -1')"
	board 'opi-slot status' > "$RUN/opi-slot-status.log" 2>&1
	say "booted slot $slot: ${result#opi-slot: }"
	case "$slot:$result" in
		trial:*"now the good slot"*)
			[[ "$(board 'cat /proc/version')" == "$1"* ]] || die 1 "the trial slot runs an unexpected kernel"
			say "running the new kernel on $BOARD_IP (promoted to the good slot)"
			;;
		trial:*)
			die 1 "the new kernel booted but did not pass the confirm check. The next boot uses the good slot. See $RUN/opi-slot-status.log"
			;;
		*)
			die 1 "the new kernel failed and the board fell back to the good slot. Serial log: ${UART_LOG:-none}. The failed slot is kept in /boot/failed-*"
			;;
	esac
	cmd_check
}

cmd_rollback() {
	need_key
	[[ -n "${RUN:-}" ]] || new_run rollback
	find_board || die 3 "board not found"
	board 'command -v opi-slot' > /dev/null 2>&1 || die 2 "this board has no A/B slots"
	board 'opi-slot rollback' || die 1 "rollback failed"
	reboot_and_wait "Power-cycle it."
	board 'opi-slot status'
	cmd_check
}

case "${1:-}" in
	setup) cmd_setup ;;
	rollback) cmd_rollback ;;
	build) cmd_build ;;
	deploy) cmd_deploy ;;
	check) cmd_check ;;
	kernel)
		cmd_build
		cmd_deploy
		;;
	*)
		sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
		exit 2
		;;
esac
