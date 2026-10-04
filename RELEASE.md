# Releasing base

## Build

```sh
sh build-base.sh                 # -> out/freelinx-base-x86_64.iso (+ .sha256)
```

What it needs and what it does is in [README.md](README.md#building).

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
   and the boot menu. Update "Current release" in README.md.
2. Build from clean trees (`mkrootfs.sh` refuses uncommitted changes in src)
   with `SERIAL=1`, the configuration the install test drives, and run every
   test above. Release that ISO, not another build.
3. Commit, tag `v<VERSION>`, push.
4. `gh release create v<VERSION> out/freelinx-base-x86_64.iso
   out/freelinx-base-x86_64.iso.sha256 -R FreeLinX/FreeLinX-base
   --notes-file NOTES.md`, then download the ISO from the release and check
   its sha256.

Never replace the files of a published release: bump the version instead.
