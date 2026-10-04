# FreeLinX base 1.0.12

A shell on the console and `xpkg` for everything else. No desktop.

```
freelinx-base-x86_64.iso    281 MB, boots on BIOS
sha256  e6ce3d382eba04cb859aeb57e9e8a38a57dfc7ed572bffa5411b49c9ea633767
```

## What works

- **It boots and shows the boot.** The whole kernel log is on the screen, then
  the screen clears and shows the banner and a prompt. 1.0.11 booted with
  `quiet loglevel=2`, which prints nothing at all on a successful boot.
- **Ctrl-C works at the console.** 1.0.11 printed `mksh: No controlling tty`
  on every boot and Ctrl-C reached nothing, because the shell had no
  controlling terminal. It does now.
- **The installer can set a password.** Step 4 of thirteen. On 1.0.11 it called
  `flxhash`, which exists nowhere — not in the repositories, not on the image —
  so it stopped on its first line.
- **The installer can create a user.** Step 9, same cause.
- **The other eleven steps** are unchanged from 1.0.11.

## What was tested

On a real QEMU boot, driving the guest over the serial line:

| | |
|---|---|
| `flxpasswd -e` | `root:!` → `root:$6$Z--$IPl/…` in `/etc/shadow` |
| `flxuseradd` | creates the account, uid 1000, in `wheel`, shell `/bin/mksh` |
| `flxhash` | no longer called from any installer file |
| screen | cleared banner, prompt in `/root`, no mksh warning |
| `stty` | present, so the password prompt does not echo |

Test suites, all passing:

| Suite | Result |
|---|---|
| `test-ui.sh` | 59 / 0 |
| `test-setup-disk.sh` | 26 / 0 |
| `test-destructive.sh` | 34 / 0 |
| `test-banner.sh` | 13 / 0 |
| `test-flxpart.sh` (ports) | 87 / 0 |
| `check-nognu.sh` | 0 violations, 355 ELF files |

**Not tested:** `test-xsetup-qemu.sh`, which drives all thirteen steps and then
boots the installed disk. Real hardware. UEFI — this host has no OVMF, so every
boot here was BIOS.

## What changed

**The installer.** `setup-passwd`, `setup-user` and `lib/ui.sh` called
`flxhash`. They now use `flxpasswd`, which is the program that exists and is on
the image, and which takes the password on stdin so it never appears in `ps`.
Both binaries are now on the image, where 1.0.11 did not have them.

**The console.** `console=tty0` is now last on every command line, so
`/dev/console` is the screen rather than a serial line that may have nothing
plugged into it. `quiet loglevel=2` is gone.

**The console shell.** `/sbin/flxconsole` replaces the two services that drew
the console before. It clears the screen before the banner, gives the shell a
controlling terminal with `setsid -c`, and starts it in `/root` instead of the
service directory. It takes the shell from `/etc/flx-shell` and shows
`/etc/motd`.

**The banner.** Written by `build-base.sh` rather than edited out of the
desktop's Plan 9 Rio banner, and the same bytes go to `/etc/issue` and
`/etc/motd`. 1.0.11's `/etc/issue` had doubled backslashes, so the logo drew
with a double stroke over SSH.

**Three build blockers.** base could not be built from a fresh clone: the
version stamp never matched the desktop banner, a check tested a run script that
no longer exists, and a console service exec'd `/usr/bin/getty` and
`/usr/libexec/toybox/login`, one of which does not exist.

## What this ISO is

It is the 1.0.11 image with those changes put in — `limine.conf`, three
installer files, two binaries, the banner and the console service. It is **not**
a build of this repository.

- Its kernel is the 1.0.11 kernel, Linux 6.18.54. This repository's kernel is
  6.6.157.
- `mkrootfs.sh` did not run, so the package set is 1.0.11's.
- The banner says 1.0.11, because `VERSION` was not changed inside the image.
- `test-xsetup-qemu.sh` was not run against it.

The two installer steps are the ones 1.0.11 could not do at all, and they were
each checked on a booted system. That is the whole of what was verified.
