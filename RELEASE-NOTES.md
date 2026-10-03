# FreeLinX base 1.0.12

**The installer works.** 1.0.11 could not set a password or create a user: both
`setup-passwd` and `setup-user` began with

```sh
need_cmd flxhash 'flxhash'
```

and there is no `flxhash`. Not in this repository, not in `ports`, not on the
1.0.11 image. Both steps stopped on their first line, which is steps 4 and 9 of
thirteen, so the two steps that make an installed system reachable at all were
the two that could not run. Passwords are hashed with `flxpasswd` now, which is
the port that exists, is on the image, and takes the password on stdin so it is
not visible in `ps`.

**You can watch it boot.** 1.0.11 booted with

```
cmdline: rdinit=/init rootfstype=ramfs console=tty0  quiet loglevel=2
```

`quiet` sets the console level to `KERN_ERR` and `loglevel=2` clamps it lower.
On a successful boot there is nothing at that level, so the screen went from the
Limine menu to a prompt with nothing in between. Neither word is on any command
line now, and the boot log is on the screen where a person is sitting.

`console=tty0` is now last on all six command lines this tree writes
(`build-base.sh`, `xsetup.d/setup-disk.sh`, `flxinstall`). `console=` is
last-one-wins for `/dev/console`, so the last one decides where `/init` and
everything it starts write. It was the serial line, which on a machine with
nothing plugged into it is the wrong place for the installer's questions.

**Ctrl-C works at the console.** It did not. `flxconsole` started the shell as a
child of a runit service, which has no controlling terminal, so on every boot:

```
/bin/mksh: No controlling tty: open /dev/tty: No such device or address
/bin/mksh: warning: won't have full job control
```

and under those two lines Ctrl-C reached nothing - no terminal to raise SIGINT
from, no foreground job to interrupt. The shell also opened in the service
directory rather than `/root`. Both services `flxconsole` replaced did `cd /root`
and `setsid -c` for exactly this, with the reason written down, so losing it was
a regression rather than a simplification. `flxconsole` does both again.

**The banner, on a clear screen.** The banner is written after clearing, so it
is not pushed off the bottom of the terminal by the boot log above it. The log
is still on the serial line, which is where it is meant to be read. `/etc/issue`
and `/etc/motd` are written by `build-base.sh` now rather than edited out of the
desktop's Plan 9 Rio banner, and they carry the same bytes - which fixes a
defect in 1.0.11, where `/etc/issue` had doubled backslashes and the logo drew
with a double stroke over SSH while `/etc/motd` drew correctly.

**base could not be built from a fresh clone.** Three separate failures, none of
them reachable from a test, which is why they survived:

- `build-base.sh` stamped the version into `/etc/issue` with a sed for
  ` FreeLinX 1.0.x` and then died unless the result was exactly
  ` FreeLinX $VERSION`. The desktop's banner says
  ` FreeLinX 1.0 (Rio Workstation Edition) - Static Musl / Linux 6.6`, so it
  never matched and the build stopped before it made an ISO.
- `mkrootfs.sh` sed `setsid -c /bin/sh -l` in `var/service/shell/run` and then
  insisted the result said `/bin/mksh -l`. That run script is now
  `exec /sbin/flxconsole`, so the sed changed nothing and the check died.
- `mkrootfs.sh` wrote a `var/service/console` that exec'd `/usr/bin/getty`,
  `/usr/libexec/toybox/login` and `/usr/bin/setsid`. Two of those three exist and
  one does not, so the service restart-looped once a second on a live medium and
  would have restart-looped forever once installed. It also competed with
  `flxconsole` for `/dev/tty1`. Deleted: `flxconsole` opens every console the
  kernel gave the machine, which is what it was for.

## Tested

In QEMU, BIOS, on an image built from a clean FreeLinX-desk tree:

- the boot log is on the screen, then a cleared screen with the banner and a
  prompt
- no `mksh` controlling-tty warning, and the prompt is in `/root`
- `setup-passwd` and `setup-user` run, hashing with `flxpasswd`

Not re-run for this release, and it should be before the tag is trusted:
`test-xsetup-qemu.sh` in both BIOS and UEFI, which drives all thirteen steps and
then boots the installed disk. It needs an ISO built with `SERIAL=1`, and
1.0.11 was published from a `SERIAL=0` build, so **the released image was not the
image the test suite drives.**

## Still known

- **A kernel message can land on the prompt.** The kernel writes at the cursor,
  and the screen is both where the boot log appears and where the shell is, so a
  message printed after the prompt is drawn is written onto it and Enter is needed
  to clear it. Usually `random: crng init done`. It needs the prompt held back
  until the kernel goes quiet, which needs `/dev/kmsg`; it was not readable on the
  image this was tested on.
- **`CONFIG_SYSFB_SIMPLEFB` matters.** `RELEASE.md` says so - if the console
  check fails with `dummy device`, the kernel has lost it and the screen is
  black. The `FreeLinX/kernel` config at 6.6.157 has it off.
- **base still needs a built FreeLinX-desk tree.** `stack/work/pkgs`, the host
  `xpkg`, the musl source tree, the Limine `bios-install` tool and the firmware
  tarball are not in git.

## Not in this release

- **The 13-step install has not been run end to end** since 1.0.9. Steps 4 and 9
  are fixed and individually checked; the other eleven are unchanged from 1.0.11.

---

Supersedes [1.0.11](https://github.com/FreeLinX/FreeLinX-base/releases/tag/v1.0.11).
