# Releasing base

## Build

```sh
sh build-base.sh                 # -> out/freelinx-base-x86_64.iso (+ .sha256)
```

It takes a few minutes. It needs `../src` (FreeLinX/src), `../ports/packages`
and network access to the signed package repository, where the 25 packages
base keeps are installed from. `BASE_FROM_DESKTOP=1` builds from a built
`../Desktop-test` instead (its `src/rootfs`, `kernel/bzImage` and
`stack/work/pkgs`).

## Test

```sh
sh test-ui.sh && sh test-setup-disk.sh && sh test-destructive.sh
SERIAL=1 OUT=out/freelinx-base-serial.iso sh build-base.sh
sh test-xsetup-qemu.sh
sh test-xsetup-qemu.sh --uefi
```

`test-xsetup-qemu.sh` boots the serial ISO and answers all 13 xsetup steps. It
then boots the installed disk without the medium, logs in as the user and as
root, and checks the hostname, time zone, groups, shell, sshd, the UUID pins,
FLX_SYS and the framebuffer console. Last, it reboots once more and checks that
a file written in the user's home is still there.

If the console check fails with `dummy device`, the kernel has lost
`CONFIG_SYSFB_SIMPLEFB`, and the screen is black.

## Publish

1. Put the version in `VERSION`. It goes into `/etc/os-release`, the banner
   and the boot menu.
2. Commit, tag `v<VERSION>`, push.
3. Build from a clean src tree (`mkrootfs.sh` refuses uncommitted changes
   there) and test as above.
4. `gh release create v<VERSION> out/freelinx-base-x86_64.iso
   out/freelinx-base-x86_64.iso.sha256 -R FreeLinX/FreeLinX-base
   -F RELEASE-NOTES.md`
