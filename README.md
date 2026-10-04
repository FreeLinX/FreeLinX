# FreeLinX base

Current release: **1.0.15** — [download](https://github.com/FreeLinX/FreeLinX-base/releases/latest)

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

Boot the ISO. The live system gives a root shell on the screen (tty1–tty3) and
on the serial line. Run:

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
| ESP (1 GB) | kernel and system image, booted by Limine on BIOS and UEFI |
| BIOS boot | Limine's BIOS stage |
| FLX_SYS | persistent `/usr /etc /var /root /bin /sbin /lib` (packages and settings survive reboots) |
| FLX_HOME | `/home` |

The installed system starts with the keymap, hostname, network, users, time
zone and services the steps set, and **asks for a login on every console**.

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
| `xorriso`, `cpio`, `xz`, `curl`, `readelf`, `git` | packing the image, fetching | `PATH` |
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
3. **Image:** the system is packed as one xz initramfs and put on a Limine
   ISO labelled `FREELINX_LIVE`, which is the label `flxupgrade` looks for.

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
```

`test-xsetup-qemu.sh` boots the ISO in QEMU/KVM, answers all 13 xsetup steps,
boots the installed disk without the medium, and logs in as the user and as
root. It checks hostname, time zone, groups, shell, sshd, ntpd, the UUID pins,
FLX_SYS and the console, then reboots and checks that a file written in the
user's home is still there.

Releasing is described in [RELEASE.md](RELEASE.md).

## Licence

BSD-2-Clause. See [LICENSE](LICENSE).
