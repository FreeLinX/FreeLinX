# FreeLinX base

[![tests](https://github.com/FreeLinX/FreeLinX-base/actions/workflows/tests.yml/badge.svg)](https://github.com/FreeLinX/FreeLinX-base/actions/workflows/tests.yml)

Current release: **1.3.0** (stable) — [download](https://github.com/FreeLinX/FreeLinX-base/releases/latest)

FreeLinX without a desktop: a shell on the console, `xpkg` for everything else.
Linux 6.18, a NetBSD userland, musl, LLVM-built, no GNU code (`check-nognu`,
0 failing).

```
freelinx-base-x86_64.iso     ~290 MB, boots on BIOS and UEFI
```

## What is on it

- **System:** runit, mdevd, dhcpcd, wpa_supplicant and `flxwifi`, ntpd, dbus,
  doas, OpenSSH 10.5 (ssh and sshd), curl, git, tmux, htop, nnn, vim (also
  `vi`), bc, e2fsprogs, dosfstools.
- **Console:** `man` (mandoc, ~200 NetBSD manual pages), `less`, `ip`
  (iproute2), `lsof`, and `mksh` as the login shell (arrow keys, history, Tab).
  `/bin/sh` stays the NetBSD sh for scripts.
- **A C compiler:** `cc` (tcc) with the musl and kernel headers.
- **Installing:** `xsetup` puts the system on a disk; `flxupgrade` upgrades an
  installed system from a newer ISO.

No X11, GTK, Mesa or fonts. Everything else: `xpkg install <name>` (the signed
repository has ~425 packages).

## Installing

Boot the ISO. The live system runs from the medium itself: the system is a
squashfs on the ISO, and only what the session changes goes to RAM (a tmpfs
overlay), so it starts in about 60 MB. It gives a root shell on the screen
(tty1–tty3) and on the serial line. Run:

```sh
xsetup
```

Thirteen steps, one question at a time. Each step is recorded, so an
interrupted install carries on where it stopped.

```
setup-keymap      setup-hostname    setup-interfaces  setup-passwd
setup-timezone    setup-proxy       setup-ntp         setup-apkrepos
setup-user        setup-sshd        setup-disk        setup-lbu
setup-apkcache
```

```sh
xsetup                  # every step not done yet, in order
xsetup --list           # the steps
xsetup --status         # which are done
xsetup --reset NAME     # forget one step, so it runs again
xsetup setup-sshd       # run one step on its own
```

`setup-disk` is the only step that writes to a disk. It erases nothing until you
type `yes`. The disk is laid out as:

| Partition | Contents |
|---|---|
| ESP (1 GB) | the kernel and Limine, for BIOS and UEFI |
| BIOS boot | Limine's BIOS stage |
| FLX_ROOT | `/`: the system, ext4 |
| FLX_HOME | `/home`, ext4 |

The installed system runs from its disk like any other. The kernel mounts
`FLX_ROOT` read-only (`root=PARTUUID=…`) with no initramfs, because the
storage drivers and ext4 are built in. `/init` then checks it with `e2fsck`,
remounts it read-write and starts the services. `/tmp` is in RAM. The boot
menu's "Rescue shell" starts no services and gives a root shell.

The installed system starts with the keymap, hostname, network, users, time
zone and services the steps set, and **asks for a login on every console**.

### After installing

```sh
passwd                      # change your password (users go through doas)
doas flxadduser bob         # another user; --admin also allows doas
doas xpkg install tmux      # packages; doas xpkg upgrade updates them
```

Only users in `wheel` can use `doas`. `setup-user` asks whether the first user
should be one, and `flxadduser NAME --admin` makes another.

### Upgrading

Boot the new release's ISO on the installed machine and run:

```sh
flxupgrade
```

It replaces the system files on the root partition (`/usr /bin /sbin /lib`,
`/init`), adds the files in `/etc` that the new release has and yours lacks,
and puts the new kernel and Limine on the boot partition. Your `/etc`
settings, users, packages and `/home` stay. Then run `doas xpkg upgrade`.

A system installed with 1.0.13–1.1.x ran from an image in RAM. `flxupgrade`
converts it: its system partition becomes the root partition, and the RAM
image is removed from the boot partition.

## Building

### What it needs

The build runs on any x86_64 Linux machine. It does **not** need a built
desktop (FreeLinX-desk).

Put these checkouts next to each other:

```
FreeLinX/
├── FreeLinX-base/   this repository
├── src/             github.com/FreeLinX/src       the root filesystem
├── ports/           github.com/FreeLinX/ports     console ports, man pages
└── drivers/         github.com/FreeLinX/drivers   Limine (bootloader/limine-binary)
```

```sh
mkdir FreeLinX && cd FreeLinX
for r in FreeLinX-base src ports drivers; do
    git clone https://github.com/FreeLinX/$r.git
done
```

You also need the following:

| Need | Why | Where it is looked for |
|---|---|---|
| `xorriso`, `mksquashfs` (squashfs-tools), `cpio`, `xz`, `curl`, `readelf`, `git` | packing the medium, fetching | `PATH` |
| a musl C compiler | builds `scripts/flxlive.c`, the live medium's 46 KB init | `LIVECC=`, then the desk's `flx-cc`, then `clang` with the musl sysroot |
| a host `xpkg` | installs the packages into the image | `XPKG=`, then `xpkg` on `PATH` |
| a musl sysroot | tcc's headers and `crt*.o` | `SYSROOT=`, then `~/freelinx/toolchain/x86_64-linux-musl` (built by [toolchain](https://github.com/FreeLinX/toolchain)) |
| network | the 25 base packages come from the signed repository | `REPO=` (default: the FreeLinX repository on Hugging Face) |
| `qemu-system-x86_64`, OVMF | only for the install test | `PATH`, `/usr/share/OVMF` |

The package index is checked against `keys/freelinx.pub` (Ed25519) before
anything from it is installed.

### Build

```sh
cd FreeLinX-base
sh build-base.sh            # -> out/freelinx-base-x86_64.iso (+ .sha256)
```

It takes a few minutes. The build does this:

1. **`scripts/mkrootfs.sh`** makes the system:
   - copies `../src/rootfs`;
   - installs the 25 packages base keeps (musl, openssl, dbus, linux,
     linux-firmware, toybox, xpkg, …) by name from the signed repository, so
     the image has a package database;
   - adds the console ports (mandoc, less, iproute2, lsof, mksh, stty, tcc),
     the manual pages and the repository key;
   - trims everything a console system does not use.

   It refuses to continue when:
   - the source tree has uncommitted changes;
   - `flxconsole` would give an installed system a shell instead of a login;
   - a program needs a library that is missing;
   - a graphical program is left;
   - `scripts/check-nognu.sh` finds GNU code.
2. **Kernel:** the linux package's own (`/usr/lib/linux/bzImage-*`), so it
   matches `/lib/modules`.
3. **Medium:** the system is packed as `boot/root.sfs` (squashfs, zstd). The
   initramfs is about 300 KB: `flxlive` as `/init` and a static `sh`.
   `flxlive` finds the volume `FREELINX_LIVE`, mounts the squashfs read-only
   with a tmpfs overlay, moves the medium to `/media/flx`, and hands over to
   the system's `/init`. All of it goes on a Limine ISO for BIOS and UEFI.

### Options

| Variable | Effect |
|---|---|
| `SERIAL=1` | kernel console on ttyS0 too (QEMU tests, headless machines) |
| `OUT=path.iso` | where the ISO goes |
| `ALLOW_DIRTY=1` | build from a source tree with uncommitted changes (testing only) |
| `FLX_HW_TARBALL=…` | extra firmware (`firmware-<kver>.tar.xz` from the desktop's `build-firmware.sh`) |
| `BASE_FROM_DESKTOP=1` | build from a built `../Desktop-test` instead (how 1.0.8–1.0.13 were made) |

## Testing

```sh
sh test-ui.sh               # xsetup's menus and prompts
sh test-setup-disk.sh       # the disk step: layout, sizes, guards, dry runs
sh test-destructive.sh      # what an install does to bytes, with the image's own tools
sh test-banner.sh           # the console banner

SERIAL=1 OUT=out/freelinx-base-serial.iso sh build-base.sh
sh test-xsetup-qemu.sh            # BIOS
sh test-xsetup-qemu.sh --uefi     # UEFI (OVMF)
sh test-upgrade-qemu.sh OLD.iso   # install OLD, flxupgrade to the new ISO
```

`test-xsetup-qemu.sh` boots the ISO in QEMU/KVM, answers all 13 xsetup steps,
boots the installed disk without the medium, and logs in as the user and as
root. It checks hostname, time zone, groups, shell, sshd, ntpd, the UUID pins,
FLX_SYS and the console, then reboots and checks that a file written in the
user's home is still there.

`test-upgrade-qemu.sh` installs an older release, leaves files in `/home` and
`/etc`, upgrades it with `flxupgrade` from the new ISO, and checks that the
disk boots the new version with both files, both passwords and the hostname
intact.

The suites that need no VM run on every push
([GitHub Actions](https://github.com/FreeLinX/FreeLinX-base/actions)), with
shellcheck. Releasing is described in [RELEASE.md](RELEASE.md).

## Licence

BSD-2-Clause. See [LICENSE](LICENSE).
