# Releasing base

Two images are built here, and they are different products.

| Image | What it is | What is on it |
|---|---|---|
| `out/base.iso` | the installer | the whole system, plus `/installer/xsetup` |
| `out/base (boot only).iso` | rescue | the rescue set only, no installer |

Both boot on BIOS and on UEFI. The boot-only image is not a stripped installer:
it is the system with no installer on it, for a machine that needs a shell to fix
something with.

## Build

```sh
cd base
sh build-base.sh both      # or: base | bootonly
```

That takes about four minutes, most of it gzipping the initramfs. The output is
in `out/`.

## Check before shipping

```sh
sh test-destructive.sh          # the installer's commands against image files
sh test-setup-disk.sh           # the conversation: geometry, guards, dry runs
sh test-ui.sh                   # the prompt library
sh ../ports/sysutils/flxpart/test-flxpart.sh
sh test-destructive-qemu.sh     # a real install to a real disk, in a VM
sh test-live-boot.sh            # boots the shipped ISO and asks the system questions
```

`test-destructive-qemu.sh` and `test-live-boot.sh` need QEMU and take a few
minutes each. The first four are quick.

## Test an install by hand

Two steps: make a disk, then boot the ISO with it attached and install.

```sh
# A 8 GiB disk to install onto.  -f because there is no file here yet.
qemu-img create -f qcow2 freelinx.qcow2 8G
```

```sh
# Boot the installer medium with the disk attached.
#
#   -m 2048        the initramfs is the whole system, uncompressed it wants more
#                  than the default
#   -smp 2         the installer is not parallel, but mdevd and the package
#                  tools are happier with a second core
#   -drive if=virtio  the disk the install goes onto.  It shows up as /dev/vda,
#                  which is what the installer looks for first
#   -cdrom         the medium, which the installer reads itself from
#   -serial        a file you can read afterwards.  The installer prints its
#                  whole conversation here, and so does anything that goes wrong
#   -vga std       a VGA adapter, so there is a graphical console as well
#   -boot d        boot the CD
#
# Then: at the FreeLinX prompt type xsetup.
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -drive file=freelinx.qcow2,if=virtio,format=qcow2 \
  -cdrom 'out/base.iso' \
  -boot d \
  -vga std \
  -serial file:install.log \
  -no-reboot
```

The answers, in order: how to store the system, which disk, and then the typed
`yes` that confirms the erase.

| Mode | What it does |
|---|---|
| 1 | nothing written; runs from RAM |
| 2 | installs onto the disk; the disk boots on BIOS and UEFI |
| 3 | one filesystem on the disk for `/var`; the system still runs from RAM |

Mode 3 is not a sys install under another name. It writes one partition, no boot
chain and no system, and the disk is not bootable — on purpose, since the kernel
and the initramfs are on the medium and every boot starts from the medium again.

To check the result without installing again, look at the disk:

```sh
qemu-img convert -O raw freelinx.qcow2 /tmp/disk.raw
```

and read `/tmp/disk.raw` with `fdisk -l`, or attach it to another VM.

### Boot the installed disk

Unmount the ISO — `-boot d` off, no `-cdrom` — and boot the disk:

```sh
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -drive file=freelinx.qcow2,if=virtio,format=qcow2 \
  -boot c \
  -vga std \
  -serial file:booted.log \
  -no-reboot
```

`booted.log` should show the kernel command line from the installed system —
`root=UUID=… rdinit=/init console=tty0 console=ttyS0,115200`, with no `quiet` —
and then the FreeLinX banner. If the screen is black and the log is empty, the
boot chain did not survive the install; check `/boot/efi` on the ESP.

`test-destructive-qemu.sh --boot-check` does exactly this second run on its own,
so the check does not have to be done by hand.

## Both files, always

Two things that are easy to get wrong, and both have happened:

**The initramfs must be built from the current rootfs.** An image that ships a
stale initramfs boots into a rescue shell and says so, and the string it prints
exists nowhere in the tree, so it is easy to misread as the boot-only image
working. `build-base.sh` builds one initramfs per image and records which, and
`iso/README.md` records the stale blobs that were there before it did.

**`textmode: yes`, inside the menu entry.** Two things about that one line, both
of which have been got wrong here:

- the key has no underscore — Limine looks up the literal string `TEXTMODE`
- it goes inside the `/FreeLinX` entry, not above it — the Linux handover reads it
  from the *entry's* config body

Get either wrong and Limine says nothing; it hands the kernel a framebuffer
instead of a text screen, `vgacon` refuses it, and the graphical console is dead
while the serial console keeps working. Since the serial console is what every
test reads, the failure is invisible until someone looks at a screen.

The symptom to recognise:

```
cat /sys/class/vtconsole/vtcon0/name
(S) dummy device
```

`(S) dummy device` means the kernel bound the dummy console: no text console
driver at all. `(S) VGA+` means vgacon is there and drawing.