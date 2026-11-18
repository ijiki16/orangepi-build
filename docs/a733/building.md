# Building Orange Pi 4 Pro (A733 / sun60iw2) images

How to build Debian images for the Orange Pi 4 Pro with `orangepi-build` on a host it does not support, and the failures to expect along the way.
Written 2026-11-16 against `orangepi-build` branch `next` (`7f24222`) and kernel `orange-pi-6.6-sun60iw2` (6.6.98).
GPU details are in [gpu.md](gpu.md). This page covers the vendor 6.6 kernel; for the mainline 7.4 kernel (Armbian `edge`), see [mainline.md](mainline.md).

## Releases for this board

`external/config/boards/orangepi4pro.conf`:

| Branch | Releases |
|---|---|
| `current` (6.6.98) | bookworm, jammy, bullseye, resolute, trixie |
| `legacy` | bookworm, jammy, bullseye |

| Release | GPU/VPU/ISP userspace on desktop images |
|---|---|
| bullseye (Debian 11) | Yes. The vendor repo is fetched only for bullseye. Needs the path fix below. |
| bookworm (Debian 12) | No. Not in the GPU branch of `family_tweaks_s`. |
| trixie (Debian 13) | Tries to install, but the packages don't exist. `pvrsrvkm.ko` only, no firmware. |

## Build host: use the Docker container

`prepare_host` accepts only focal, jammy or noble as the host. On anything else, such as Ubuntu 26.04 "resolute", it stops with:

```
It seems you ignore documentation and run an unsupported build system: resolute
```

`./build.sh docker …` works around this, but it runs `docker run -it`. That needs a TTY, so it fails from scripts, CI and agents.
Run the container directly instead:

```bash
cd orangepi-build
bash .claude/skills/orangepi-a733-image-build/run-build.sh /tmp/build.log \
  BOARD=orangepi4pro BRANCH=current RELEASE=trixie BUILD_OPT=image \
  BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no \
  DOWNLOAD_MIRROR=eu IGNORE_UPDATES=yes COMPRESS_OUTPUTIMAGE=sha,img
```

What `run-build.sh` does:
- Builds `orangepi:latest` from `userpatches/Dockerfile` (Ubuntu 22.04). No build context is needed.
- Runs the container with the flags `config-docker.conf` uses: loop devices, cgroup rules, `/dev` at `/tmp/dev`, and the `orangepi-cache`/`orangepi-ccache` volumes.
- Requirements: the user is in the `docker` group, and qemu-aarch64 binfmt is registered on the host with the `F` flag. Check with `cat /proc/sys/fs/binfmt_misc/qemu-aarch64`.

For a desktop build, also pass these so no menu appears:

```
BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce DESKTOP_ENVIRONMENT_CONFIG_NAME=config_base DESKTOP_APPGROUPS_SELECTED=
```

`config_base` exists for xfce on bullseye, bookworm and trixie (`external/config/desktop/<release>/environments/xfce/`).

Typical times on 12 cores: server about 24 min, xfce desktop about 34 min, with the kernel tree already compiled.

Output lands in `output/images/<name>/<name>.img`, with a `.sha` file next to it.
Files in `output/` are root-owned, so delete them through the container.

## Failures seen and their fixes

### 1. `modpost: version 'GLIBC_2.38' not found`

`compile_kernel` fails at `MODPOST Module.symvers`.

- **Cause:** the kernel tree has host tools left from an earlier build directly on the newer host. `scripts/mod/modpost` needs glibc 2.38, and the jammy container has 2.35. Make treats the binary as up to date and doesn't rebuild it.
- **Fix:** delete the stale host tool and its objects. Deleting only the binary is not enough: the objects were compiled against newer glibc headers.

  ```bash
  cd kernel/orange-pi-6.6-sun60iw2
  rm -f scripts/mod/{modpost,modpost.o,file2alias.o,sumversion.o,symsearch.o} scripts/mod/.{modpost,modpost.o,file2alias.o,sumversion.o,symsearch.o}.cmd
  ```

- **Check others:** list the remaining x86 host binaries and the glibc each needs. Anything above 2.35 must go too.

  ```bash
  find . -path ./.git -prune -o -type f -perm -u+x -print0 | xargs -0 file | grep 'ELF 64-bit.*x86-64' | cut -d: -f1 |
    while read f; do echo "$(objdump -T "$f" | grep -o 'GLIBC_2\.[0-9]*' | sort -V | tail -1) $f"; done | sort -V
  ```

### 2. `linux-image-current-sun60iw2 … post-installation script … exit status 127`

`install_deb_chroot` fails.

- **Direct cause:** the kernel `postinst` runs `mkimage` under `set -e`. `mkimage` comes from `u-boot-tools`, which was never installed.
- **Why it wasn't installed:** the main `apt-get install $PACKAGE_MAIN_LIST` aborted on `E: Unable to locate package iozone3`. Look for this line in the build log.
- **Why apt couldn't find it:**
  - `iozone3` is in `non-free`.
  - The rootfs adds **armhf** as a foreign architecture.
  - `debian.grena.ge` doesn't mirror armhf, so `trixie/main/binary-armhf/Packages` returns 404.
  - apt commits every index of a suite as one transaction, so one 404 throws away the whole suite's new indexes, the `non-free` one included. Only debootstrap's `main` list stays.
- **Telltale signs:** `Hit: … trixie InRelease`, then `E: Failed to fetch …binary-armhf/Packages 404`, then the warning `Updating package lists [ failed ]`.
- **Fix:** use a mirror that carries armhf. The `eu` mirror code in `scripts/configuration.sh` now checks for `dists/stable/main/binary-armhf/Release` and falls back to `deb.debian.org` (see §5 for why not `ftp.nl`).
- **To reproduce in 30 s:**

  ```bash
  docker run --rm debian:trixie bash -c 'dpkg --add-architecture armhf; rm -f /etc/apt/sources.list.d/*;
    printf "Types: deb\nURIs: http://debian.grena.ge/debian\nSuites: trixie\nComponents: main non-free\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n" > /etc/apt/sources.list.d/t.sources;
    apt-get -qq update >/dev/null 2>&1; apt-cache policy iozone3 | grep Candidate'   # empty = broken mirror
  ```

### 3. A broken rootfs cache gets saved

- **Cause:** `scripts/debootstrap.sh:326` checks `${PIPESTATUS[0]}` after an `eval … ;EVALPIPE=(…)`. By then PIPESTATUS belongs to the assignment, so a failed main package install doesn't stop the build. The rootfs is then cached without its packages, and later builds reuse it.
- **Fix:** after any main-install failure, delete the cache entry written by that run:

  ```bash
  ls -la --time-style=full-iso external/cache/rootfs/   # match the timestamp to the failed run
  docker run --rm -v "$PWD/external/cache/rootfs:/r" --entrypoint sh orangepi:latest -c 'rm -v /r/<release>-<cli|xfce…>-arm64.<hash>.tar.lz4*'
  ```

  Upstream line 326 is not patched.

### 4. Vendor GPU/VPU/ISP packages skipped silently, bullseye included

- **Cause:**
  - Upstream `a05b3b4` (2026-04-21) switched `family_tweaks_s` to a flat layout: `sun60iw2_packages/libcedarc`, `xserver_${RELEASE}/`, `vlc_${RELEASE}/`.
  - The public repo (`orangepi-xunlong/rk-rootfs-build@sun60iw2_packages`, `7b6d78d`) still uses `bullseye/libcedarc`, `bullseye/xserver` and `bullseye/vlc`.
  - `dpkg_install_debs_chroot` returns silently when a folder is missing, and the xserver `cp`/`dpkg -i` errors go only to `install.log`.
- **Fix:** `external/config/sources/families/sun60iw2.conf` now resolves each folder through `sun60iw2_pkgdir`. It tries the flat path first, then `<release>/<name>` with any `_<release>` suffix removed. If neither exists, it prints `sun60iw2 vendor package dir missing` to stderr.

### 5. bullseye: `Certificate verification failed: The name in the certificate does not match`

This shows up downstream as the same kernel postinst `exit status 127` as §2.

- **Cause:**
  - `create_sources_list` writes bullseye's sources with `https://`; every other release uses `http://`.
  - `ftp.nl.debian.org` is a DNS alias for a University of Twente server. Its certificate covers only `*.snt.utwente.nl`, so every bullseye index fails, the main install aborts, and `u-boot-tools` is missing.
- **Check a mirror:**

  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' https://<mirror>/debian/dists/bullseye/Release   # 000 + exit 60 = bad cert
  ```

- **Fix:** the `eu` fallback is now `deb.debian.org` (valid cert, armhf, `debian-security`), and security comes from `deb.debian.org/debian-security`. A bullseye rootfs cache written by the failed run is unusable; delete it as in §3. A cache far smaller than the other releases' caches gives it away (234 MB vs about 1.3 GB for xfce).

### 6. bullseye: `Failed to fetch …/debian-security/pool/updates/… 404 Not Found`

- **Symptom:** the build warns `Upgrading base packages [ failed ]`, then the kernel postinst fails with `exit status 127` as in §2.
- **Cause:**
  - Bullseye LTS ended in August 2026, and `bullseye-security` moved to `archive.debian.org`.
  - deb.debian.org, security.debian.org and the country mirrors still serve its frozen index (dated 2026-09-12), but the pool files are gone, so every package apt picks from it returns 404.
  - `bullseye` and `bullseye-updates` on the normal mirrors are still complete.
- **Fix:** `scripts/configuration.sh` sets `DEBIAN_SECURTY='archive.debian.org/debian-security'` for `RELEASE=bullseye`, whatever the mirror. The archive suite has no `Valid-Until`, so apt doesn't reject it as expired.
- **Check:**

  ```bash
  f=pool/updates/main/a/alsa-lib/libasound2_1.2.4-1.1%2bdeb11u1_arm64.deb
  for b in https://deb.debian.org/debian-security https://archive.debian.org/debian-security; do curl -sI -o /dev/null -w "%{http_code} $b\n" $b/$f; done
  ```

- Expect the same to happen to `bullseye` and `bullseye-updates` once they are archived, and to bookworm when its LTS ends (2028-06).

### 7. bullseye: `Installation of vlc failed`, `vlc-plugin-base depends on vlc-data (= 3.0.21-0+deb11u1)`

- **Cause:**
  - The vendor `vlc-plugin-base_3.0.21-0+deb11u1` from `sun60iw2_packages/bullseye/vlc` requires `vlc-data` at exactly its own version.
  - Debian's final bullseye-security update moved VLC to 3.0.23, so the rootfs already has the newer `vlc-data`. `dpkg -i` then leaves the plugin unconfigured.
  - This code never ran before the §4 path fix, so the problem was hidden.
- **Fix:** before the vendor VLC install, `family_tweaks_s` reads the required `vlc-data` version from the vendor deb. It downgrades every installed package built from the `vlc` source to that version with `--allow-downgrades`; 3.0.21-0+deb11u1 is still in bullseye `main`. Then it holds them.
- **Trade-off:** the image ships VLC 3.0.21, like the original Orange Pi bullseye images, without the 3.0.22/3.0.23 security fixes.
- **Unaffected:** the rootfs cache (written before `family_tweaks_s`) is fine, so don't delete it for this failure.

## Local changes to this tree (not upstream)

| File | Change |
|---|---|
| `scripts/configuration.sh` | `DOWNLOAD_MIRROR=eu`: grena.ge first, falling back to `deb.debian.org` when grena has no armhf. `debian-security` comes from `deb.debian.org`, except bullseye, which always uses `archive.debian.org/debian-security`. |
| `scripts/general.sh` | trixie uses deb822 `debian.sources` |
| `external/config/templates/config-example.conf` | documents the `eu` mirror |
| `external/config/sources/families/sun60iw2.conf` | `sun60iw2_pkgdir` vendor folder resolver; VLC version alignment before the vendor VLC install (§7) |

## Checking an image

```bash
bash .claude/skills/orangepi-a733-image-build/verify-image.sh output/images/<name>/<name>.img
```

It checks:
- the SHA-256
- the partition table (ext4 at sector 65536 = 32 MiB)
- `eGON.BT0` at 8 KiB and `sunxi-package` at 16400 KiB
- `/boot` (uImage, uInitrd, boot.scr, orangepiEnv.txt, the 4 Pro DTB)
- key packages
- the GPU stack: `pvrsrvkm.ko`, `rgx.fw.36.56.104.183`, `libsrv_um`, `libVK_IMG`, `pvr_dri.so`

The rootfs is read with `debugfs` at an offset, so no mounting and no root are needed.

## Flashing

```bash
sudo dd if=<image>.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Serial console: `ttyS0` at 115200.
