/* SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2026 FreeLinX OS Project.
 *
 * flxlive - pid 1 of the live medium's initramfs.
 *
 * The live system is not unpacked into RAM.  This finds the medium (the
 * ISO 9660 volume FREELINX_LIVE: a CD, a USB stick, a disk image), mounts the
 * system on it (boot/root.sfs, squashfs) read-only, puts a tmpfs over it with
 * overlayfs so the live session can write, and hands over to the system's own
 * /init.  RAM holds what the session changes and the page cache, not a copy
 * of the system.  This is what other distributions' live media do.
 *
 * It is a C program and not a script because a switch_root needs MS_MOVE,
 * chroot and a loop device, and the userland has no switch_root, chroot or
 * losetup.  If anything fails it says what and starts /bin/sh.
 *
 * Kernel options it reads: flx.medium=LABEL (default FREELINX_LIVE).
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/loop.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static void say(const char *m) { fprintf(stderr, "flxlive: %s\n", m); }

static void rescue(const char *why)
{
	fprintf(stderr, "flxlive: %s (%s)\nflxlive: starting a shell; the medium is not mounted.\n",
		why, strerror(errno));
	execl("/bin/sh", "sh", (char *)0);
	for (;;) pause();
}

/* The ISO 9660 primary volume descriptor is at byte 32768: type 1, "CD001",
 * and the volume id at offset 40, 32 bytes padded with spaces. */
static int has_label(const char *dev, const char *label)
{
	unsigned char b[72];
	int fd = open(dev, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return 0;
	ssize_t n = pread(fd, b, sizeof b, 32768);
	close(fd);
	if (n != (ssize_t)sizeof b || b[0] != 1 || memcmp(b + 1, "CD001", 5)) return 0;
	size_t l = strlen(label);
	if (l > 32 || memcmp(b + 40, label, l)) return 0;
	for (size_t i = l; i < 32; i++) if (b[40 + i] != ' ') return 0;
	return 1;
}

static int find_medium(const char *label, char *dev, size_t len)
{
	DIR *d = opendir("/sys/class/block");
	struct dirent *e;
	int found = 0;
	if (!d) return 0;
	while (!found && (e = readdir(d))) {
		if (e->d_name[0] == '.' || !strncmp(e->d_name, "loop", 4) || !strncmp(e->d_name, "ram", 3))
			continue;
		snprintf(dev, len, "/dev/%s", e->d_name);
		found = has_label(dev, label);
	}
	closedir(d);
	return found;
}

static int loop_attach(const char *file, char *dev, size_t len)
{
	int ctl = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
	if (ctl < 0) return -1;
	int n = ioctl(ctl, LOOP_CTL_GET_FREE);
	close(ctl);
	if (n < 0) return -1;
	snprintf(dev, len, "/dev/loop%d", n);
	int ffd = open(file, O_RDONLY | O_CLOEXEC);
	int lfd = open(dev, O_RDWR | O_CLOEXEC);
	if (ffd < 0 || lfd < 0) return -1;
	struct loop_config c;
	memset(&c, 0, sizeof c);
	c.fd = (unsigned)ffd;
	/* no AUTOCLEAR: it detaches the device on the close below, before the mount */
	c.info.lo_flags = LO_FLAGS_READ_ONLY;
	int r = ioctl(lfd, LOOP_CONFIGURE, &c);
	if (r < 0) {	/* kernels before 5.8 */
		r = ioctl(lfd, LOOP_SET_FD, ffd);
		if (r == 0) {
			struct loop_info64 i;
			memset(&i, 0, sizeof i);
			i.lo_flags = LO_FLAGS_READ_ONLY;
			ioctl(lfd, LOOP_SET_STATUS64, &i);
		}
	}
	close(ffd);
	close(lfd);
	return r;
}

/* the value of NAME= on the kernel command line, or DEF */
static const char *cmdline(const char *name, const char *def)
{
	static char buf[4096], val[256];
	int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
	if (fd < 0) return def;
	ssize_t n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if (n <= 0) return def;
	buf[n] = 0;
	size_t nl = strlen(name);
	for (char *p = strtok(buf, " \n"); p; p = strtok(0, " \n"))
		if (!strncmp(p, name, nl) && p[nl] == '=') {
			snprintf(val, sizeof val, "%s", p + nl + 1);
			return val;
		}
	return def;
}

int main(void)
{
	char medium[64], loop[32];

	mkdir("/proc", 0555); mkdir("/sys", 0555); mkdir("/dev", 0755);
	mount("proc", "/proc", "proc", 0, 0);
	mount("sysfs", "/sys", "sysfs", 0, 0);
	mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
	/* The initramfs has no /dev/console node of its own, so the kernel could
	 * not give pid 1 a terminal: take it from devtmpfs. */
	int con = open("/dev/console", O_RDWR | O_NOCTTY);
	if (con >= 0) {
		dup2(con, 0); dup2(con, 1); dup2(con, 2);
		if (con > 2) close(con);
	}
	mkdir("/run", 0755);
	if (mount("tmpfs", "/run", "tmpfs", 0, "mode=0755"))
		rescue("cannot mount a tmpfs on /run");

	const char *label = cmdline("flx.medium", "FREELINX_LIVE");
	/* USB sticks and CD drives appear a moment after the kernel starts. */
	int tries;
	for (tries = 0; tries < 300 && !find_medium(label, medium, sizeof medium); tries++)
		usleep(100000);
	if (tries == 300) {
		fprintf(stderr, "flxlive: no medium labelled %s after 30 seconds\n", label);
		rescue("the live medium was not found");
	}

	mkdir("/run/medium", 0755);
	if (mount(medium, "/run/medium", "iso9660", MS_RDONLY, 0))
		rescue("cannot mount the medium");
	if (loop_attach("/run/medium/boot/root.sfs", loop, sizeof loop))
		rescue("cannot attach boot/root.sfs to a loop device");
	mkdir("/run/lower", 0755);
	if (mount(loop, "/run/lower", "squashfs", MS_RDONLY, 0))
		rescue("cannot mount the system (squashfs)");

	/* the writable layer: everything the live session changes, in RAM */
	mkdir("/run/rw", 0755);
	if (mount("tmpfs", "/run/rw", "tmpfs", 0, "mode=0755"))
		rescue("cannot mount the tmpfs for the writable layer");
	mkdir("/run/rw/upper", 0755);
	mkdir("/run/rw/work", 0755);
	mkdir("/newroot", 0755);
	if (mount("overlay", "/newroot", "overlay", 0,
		  "lowerdir=/run/lower,upperdir=/run/rw/upper,workdir=/run/rw/work"))
		rescue("cannot mount the overlay");

	/* The medium stays reachable from the system at /media/flx (read-only),
	 * where flxupgrade and the installer look for it. */
	mkdir("/newroot/media", 0755);
	mkdir("/newroot/media/flx", 0755);
	mount("/run/medium", "/newroot/media/flx", 0, MS_MOVE, 0);
	mount("/dev", "/newroot/dev", 0, MS_MOVE, 0);
	umount2("/proc", MNT_DETACH);
	umount2("/sys", MNT_DETACH);

	/* switch_root: the overlay becomes /, and the system's /init takes over */
	if (chdir("/newroot") || mount(".", "/", 0, MS_MOVE, 0) || chroot(".") || chdir("/"))
		rescue("cannot switch to the new root");
	say("the system is on the medium; changes go to RAM");
	execl("/init", "/init", (char *)0);
	rescue("cannot run /init");
	return 1;
}
