#!/usr/bin/env bash
# Run an orangepi-build image build inside the Ubuntu 22.04 build container, without a TTY.
# (./build.sh docker uses `docker run -it`, which fails from scripts/agents; hosts other than
# focal/jammy/noble fail prepare_host's release check when building natively.)
#
# Usage (from the orangepi-build root):
#   bash .claude/skills/orangepi-a733-image-build/run-build.sh <log-file> KEY=VALUE...
# Exit status is the build's own (build.sh exits 255 on any exit_with_error).
set -uo pipefail

log=${1:?usage: run-build.sh <log-file> KEY=VALUE...}; shift
[[ -f build.sh && -d external/config/boards ]] || { echo "run from the orangepi-build root" >&2; exit 2; }
id -nG | grep -qw docker || { echo "user is not in the docker group" >&2; exit 2; }
grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null ||
	echo "warning: qemu-aarch64 binfmt not enabled on the host; the rootfs stage will fail" >&2

if ! docker image inspect orangepi:latest >/dev/null 2>&1; then
	dockerfile=userpatches/Dockerfile
	[[ -f $dockerfile ]] || dockerfile=external/config/templates/Dockerfile
	echo "building orangepi:latest from $dockerfile" >&2
	docker build -t orangepi:latest - < "$dockerfile" || exit 1   # no COPY in it: empty context
fi

flags=(--rm --cap-add=SYS_ADMIN --cap-add=MKNOD --cap-add=SYS_PTRACE --security-opt=apparmor:unconfined)
for d in /dev/loop*; do flags+=(--device="$d"); done
flags+=(--device-cgroup-rule='b 7:* rmw' --device-cgroup-rule='b 259:* rmw' -v /dev:/tmp/dev:ro)
flags+=(-v "$PWD/:/root/orangepi/" -v orangepi-cache:/root/orangepi/cache -v orangepi-ccache:/root/.ccache)
flags+=(-e COLUMNS=200 -e LINES=50 --name "orangepi-build-$$")

docker run "${flags[@]}" orangepi:latest "$@" > "$log" 2>&1
rc=$?
echo "EXIT=$rc" >> "$log"

# Summary: status lines plus the failures that do NOT stop the build on their own.
plain() { sed 's/\x1b\[[0-9;]*m//g; s/\r/\n/g' "$log"; }
plain | grep -E '\[ (error|warn) \]|Done building|Runtime' | tail -15
plain | grep -E 'Unable to locate package|Failed to fetch|vendor package dir missing' | sort -u | head -10
cp -f output/debug/install.log "${log%.log}.install.log" 2>/dev/null &&
	grep -iE 'error|cannot|No such file' "${log%.log}.install.log" | sort -u | head -10
exit $rc
