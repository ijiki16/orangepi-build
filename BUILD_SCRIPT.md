# Orange Pi Build Script Documentation

This document describes the entrypoint `build.sh` used by the Orange Pi build repository.

## Purpose

`build.sh` is the main wrapper script for starting the Orange Pi build process. It handles:

- environment setup and permissions
- optional self-update behavior
- selecting and loading build configuration
- preparing `userpatches` examples and directories
- bootstrapping Docker/Vagrant use cases
- launching the proper build path (`scripts/main.sh` or `scripts/build-all-ng.sh`)

> Do not edit `build.sh` directly. Customize your build through configuration files under `userpatches/`.

## Requirements

- Bash
- `realpath`
- Git
- A working build tree with `scripts/general.sh` present
- No whitespace in the repository path (`build.sh` will abort if the path contains spaces)

## Startup Flow

1. Resolve `SRC` to the repository root and change into it.
2. Optionally enable call tracing if `ORANGEPI_ENABLE_CALL_TRACING=yes`.
3. Source `scripts/general.sh` and make build helper functions available.
4. Process command-line `LIB_TAG=...` values to switch branches locally.
5. Attempt a source update unless `.ignore_changes` exists.
6. Reinvoke itself with `sudo` when needed so the build runs with root privileges.
7. Prepare host utilities unless `OFFLINE_WORK=yes`.
8. Handle Docker/Vagrant mode selection.
9. Ensure `userpatches/` exists and generate example configuration files if missing.
10. Determine the build configuration file to use, source it, and then execute the build engine.

## Configuration Selection

`build.sh` supports several ways to choose a configuration file.

### Named config alias

If the first positional argument matches `userpatches/config-<name>.conf`, then that file becomes the build config.

Example:

```bash
./build.sh docker
```

This loads `userpatches/config-docker.conf` if it exists.

### Explicit `CONFIG`

You can set `CONFIG` directly:

```bash
CONFIG=userpatches/config-custom.conf ./build.sh
```

or

```bash
./build.sh CONFIG=userpatches/config-custom.conf
```

### Default config fallback

If `CONFIG` is not set and `userpatches/config-default.conf` exists, `build.sh` uses that file.

## Userpatches and example config generation

`build.sh` ensures the `userpatches/` directory exists and creates sample files when needed:

- `userpatches/config-example.conf`
- `userpatches/config-default.conf` (symlink to `config-example.conf` if missing)
- `userpatches/config-docker.conf`
- `userpatches/Dockerfile`
- `userpatches/config-vagrant.conf`
- `userpatches/Vagrantfile`

If old `.conf` files are present in the repository root, the script migrates them into `userpatches/`.

## Special modes

### Docker mode

Use:

```bash
./build.sh docker
```

If Docker is missing on Debian-based hosts, `build.sh` can install it automatically and rerun itself.

### Docker shell mode

Use:

```bash
./build.sh docker-shell
```

This sets `SHELL_ONLY=yes` and enters Docker mode without starting the build automatically.

### Docker purge

Use:

```bash
./build.sh dockerpurge
```

This removes existing Orange Pi Docker containers and images before continuing in Docker mode.

### Vagrant mode

Use:

```bash
./build.sh vagrant
```

If Vagrant is not installed, `build.sh` will attempt to install `vagrant` and `virtualbox`.

## Root privilege handling

`build.sh` generally requires root privileges.

- If not run as root, it automatically retries itself with `sudo`.
- It allows non-root execution when launched as `vagrant`, or when the first argument is `docker`, `dockerpurge`, or `docker-shell` and the user is in the `docker` group.

## Build entrypoint selection

After configuration loading, `build.sh` chooses one of two build engines:

- `scripts/build-all-ng.sh` when `BUILD_ALL=yes` or `BUILD_ALL=demo`
- `scripts/main.sh` for normal builds

## Building images and rootfs

`build.sh` supports several build targets via `BUILD_OPT`:

- `image` — full flashable OS image
- `rootfs` — root filesystem and package set only
- `kernel` — kernel package build only
- `u-boot` — U-Boot bootloader build only

For a full OS image, set `BUILD_OPT=image` and provide the target board, kernel branch, and OS release.

```bash
./build.sh BOARD=orangepi-5 BRANCH=next BUILD_OPT=image RELEASE=bullseye BUILD_DESKTOP=yes
```

For a minimal console image:

```bash
./build.sh BOARD=orangepi-5 BRANCH=next BUILD_OPT=image RELEASE=bullseye BUILD_MINIMAL=yes
```

For a rootfs-only build:

```bash
./build.sh BOARD=orangepi-5 BRANCH=next BUILD_OPT=rootfs RELEASE=bullseye
```

For kernel or bootloader builds:

```bash
./build.sh BOARD=orangepi-5 BRANCH=next BUILD_OPT=kernel
./build.sh BOARD=orangepi-5 BRANCH=next BUILD_OPT=u-boot
```

If any of these values are omitted, `scripts/main.sh` will prompt for them interactively.

## Common build arguments

The following environment variables are recognized by `build.sh` and `scripts/main.sh`:

- `BOARD` — target board name (must match `external/config/boards/<board>.conf`)
- `BRANCH` — kernel branch (`current`, `legacy`, `next`, etc.)
- `BUILD_OPT` — build action (`image`, `rootfs`, `kernel`, `u-boot`)
- `RELEASE` — OS release package base (Debian/Ubuntu release)
- `BUILD_DESKTOP` — `yes` to build a desktop image
- `BUILD_MINIMAL` — `yes` to build a minimal console image
- `KERNEL_CONFIGURE` — `yes` or `no` to show kernel config menu before compilation
- `DESKTOP_ENVIRONMENT` — desktop environment identifier when building a desktop image
- `DESKTOP_ENVIRONMENT_CONFIG_NAME` — optional desktop config name
- `DESKTOP_APPGROUPS_SELECTED` — optional selected desktop app groups
- `DESKTOP_APT_FLAGS_SELECTED` — optional APT flags for desktop packages
- `COMPRESS_OUTPUTIMAGE` — optional compression setting for the output image
- `BUILD_ALL` — `yes` or `demo` to run `scripts/build-all-ng.sh`

## Command-line parameter overrides

Any extra arguments of the form `NAME=value` are applied to the build environment.

Example:

```bash
./build.sh BOARD=orangepi-5 BRANCH=next
```

This sets `BOARD` and `BRANCH` for the current build.

## Notes

- `build.sh` is intentionally conservative about updating the repository when local changes exist.
- If `LIB_TAG` is provided, the script only switches branches when that branch exists locally.
- Config files are sourced from the resolved config directory, which becomes `USERPATCHES_PATH` unless overridden by the config.
