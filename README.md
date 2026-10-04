# FreeLinX base

[![tests](https://github.com/FreeLinX/FreeLinX-base/actions/workflows/tests.yml/badge.svg)](https://github.com/FreeLinX/FreeLinX-base/actions/workflows/tests.yml)

Current release: **1.3.1** (stable) — [download](https://github.com/FreeLinX/FreeLinX-base/releases/latest) · [documentation](https://freelinx.github.io/FreeLinX/)

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

No X11, GTK, Mesa or fonts on the image. Everything else: `xpkg install <name>`
(the signed repository has ~428 packages); see [A desktop](#a-desktop).

## Trying it

In QEMU (KVM). Make a disk once, boot the ISO and run `xsetup`:

```sh
qemu-img create -f qcow2 flx.qcow2 20G       # once: this empties the disk
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 \
  -drive file=flx.qcow2,if=virtio,format=qcow2 \
  -cdrom freelinx-base-x86_64.iso -boot d \
  -device VGA,xres=1600,yres=900 \
  -nic user,model=virtio-net-pci
```

Then boot the installed disk, without the ISO:

```sh
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 2 \
  -drive file=flx.qcow2,if=virtio,format=qcow2 \
  -device VGA,xres=1600,yres=900 \
  -nic user,model=virtio-net-pci
```

- `xres`/`yres` is the screen size the system takes, both on the console and in X.
- For UEFI, add `-machine q35` and the OVMF firmware.
- "No bootable device" means the disk has no system on it yet: install first.

On a real machine, write the ISO to a USB stick and boot it. BIOS and UEFI
both work; Secure Boot has to be off.

```sh
sudo dd if=freelinx-base-x86_64.iso of=/dev/sdX bs=4M conv=fsync
```

Check with `lsblk` that `/dev/sdX` is the stick: `dd` erases it.

In the live session, what you change is kept in RAM (up to 75% of it). Large
packages such as Firefox need an installed system, or more RAM.

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

### A desktop

```sh
xpkg install xorg xinit openbox      # pulls in fonts, st and the keymaps
startx
```

Right-click the desktop for the menu (Terminal, Reconfigure, Restart, Exit).
Without `~/.xinitrc`, `startx` starts openbox with an `st` terminal. Your own
`~/.xinitrc` should end in `exec openbox --startup st`: a terminal started
next to openbox can come up before openbox manages the screen and never show.
`xrandr -s 1920x1080` (package `xrandr`) changes the screen size. Firefox:
`xpkg install firefox`.

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
desktop (FreeLinX-desk), and it needs no root.

**1. Host tools** (Debian/Ubuntu names):

```sh
sudo apt install git curl python3 openssl xorriso squashfs-tools cpio xz-utils binutils
# only for the QEMU tests:
sudo apt install qemu-system-x86 qemu-utils ovmf
```

**2. The sources, next to each other:**

```sh
mkdir FreeLinX && cd FreeLinX
for r in FreeLinX-base src ports drivers; do
    git clone https://github.com/FreeLinX/$r.git
done
```

**3. The FreeLinX toolchain** (clang + LLD + a musl sysroot; it builds the live
medium's small init). Unpack its release next to them:

```sh
curl -LO https://github.com/FreeLinX/toolchain/releases/download/v1.0.0/toolchain.tar.gz
tar -xzf toolchain.tar.gz           # -> FreeLinX/toolchain/
```

You end up with:

```
FreeLinX/
├── FreeLinX-base/   this repository: the build, the installer, the tests
├── src/             the root filesystem
├── ports/           console ports (mandoc, less, mksh, tcc, ...)
├── drivers/         Limine (bootloader/limine-binary)
└── toolchain/       clang, lld, the musl sysroot
```

Everything else is fetched, and checked, during the build:

| What | From | Checked by |
|---|---|---|
| the 26 packages base is made of (musl, openssl, linux, xpkg, …) | the signed package repository | Ed25519 index signature (`keys/freelinx.pub`), sha256 per archive |
| a host `xpkg`, when this machine has none | the same repository | the same |
| `file-5.46.tar.gz` (for `magic.mgc`) | the FreeLinX source mirror | its recorded sha256 |

Every input can be pointed elsewhere: `XPKG`, `SYSROOT`, `LIVECC`, `REPO`,
`LIMINE_DIR`, `FLXSRC`.

### Build

```sh
cd FreeLinX-base
sh build-base.sh            # -> out/freelinx-base-x86_64.iso (+ .sha256)
```

It takes a few minutes and downloads about 150 MB. The build does this:

1. **`scripts/mkrootfs.sh`** makes the system:
   - copies `../src/rootfs`;
   - installs the 25 packages base keeps (musl, openssl, dbus, linux,
     linux-firmware, toybox, xpkg, …) and musl-dev by name from the signed
     repository, so the image has a package database;
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
