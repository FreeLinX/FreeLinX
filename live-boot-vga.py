#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# live-boot-vga.py - read the guest's VGA text buffer out of guest memory.
#
# A virtual terminal in text mode draws into the VGA text buffer at 0xb8000, not
# into a framebuffer and not onto anything a serial line carries.  So the only way
# to ask what tty1 is showing is to read that memory, and the only way to read it
# is through the QEMU monitor:
#
#     xp /2000xh 0xb8000
#
# which prints the bytes as halfwords with an address on each line.
#
# pmemsave to a file would need the guest's filesystem readable to get the file
# back, and the guest's filesystem is the thing that has not been established yet
# at this point in a boot.  Reading the memory directly has no such dependency.
#
# Why the text buffer and not a framebuffer
# ------------------------------------------
# base has no desktop: no X server, no window manager, no X client.  Verified on
# the shipped kernel:
#
#     Console: colour VGA+ 80x25
#     /sys/class/vtconsole/vtcon0/name: (S) VGA+
#     /dev/dri: No such file or directory
#     /dev/fb0: No such file or directory
#
# No DRM driver loads, so there is no framebuffer, so vgacon is the console and it
# writes to the text buffer.  CONFIG_FB is off in the kernel and stays off.
#
# An earlier version of this reader also handled the case where fbcon had taken the
# console over onto a framebuffer, by screenshotting the guest and looking at the
# pixels.  That was written for a kernel config base no longer uses, and it could
# not read the text anyway - only report that something was drawn.  It is gone
# rather than left as a path that cannot be reached, and the reader says which
# console it found so that a kernel which does bind fbcon is visible as a change
# rather than as a blank screen.
#
# 0xb8000 is the colour VGA text buffer: 80x25 cells of two bytes, a character
# and an attribute, 4000 bytes in all.  `xp /2000xh` reads exactly that: 0x2000
# halfwords is 0x4000 bytes.
import re
import socket
import sys
import time

BASE = 0xB8000
SIZE = 0x4000
ROWS, COLS = 25, 80


class Monitor:
    """A QEMU monitor on a unix socket.

    It answers one command at a time and echoes what it is sent, character by
    character with erase sequences, so replies are matched on their own content
    rather than by offset into the stream.
    """

    def __init__(self, path):
        self.buf = ""
        end = time.time() + 30
        while time.time() < end:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                self.sock.settimeout(0.5)
                return
            except OSError:
                time.sleep(0.2)
        raise SystemExit("live-boot-vga: cannot connect to the monitor at %s" % path)

    def _drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                return
            self.buf += chunk.decode("utf-8", "replace")

    def command(self, cmd, seconds=10):
        self._drain(0.4)
        self.buf = ""
        self.sock.sendall((cmd + "\n").encode())
        end = time.time() + seconds
        while time.time() < end:
            self._drain(0.3)
            if re.search(r"\(qemu\)\s*$", self.buf):
                break
        return self.buf


def read_text_buffer(dump):
    """Decode the text buffer into a list of non-empty rows of text."""
    cells = {}
    for line in dump.splitlines():
        # The address is matched anywhere on the line, and without the leading
        # "0x".
        #
        # The monitor is a terminal: it echoes what it is sent with erase
        # sequences around every character, so the line arrives as
        #
        #     ...xp /2000xh 0xb8000<ESC>[K
        #     000b8000: 0x0765 0x0761 ...
        #
        # and "000b8000:" is preceded by the tail of an escape sequence, not by
        # whitespace. Anchoring on \s* matches nothing at all, the buffer comes
        # back empty, and the reader reports a blank screen on a console with a
        # login shell on it.
        #
        # That is the same failure as the bug this reader was written to catch, in
        # the tool built to catch it: a check that cannot see the thing it checks
        # and reports the opposite of the truth. It reported a dead console while
        # the buffer held "login shell on /dev/tty1".
        m = re.search(r"([0-9a-fA-F]{6,}):\s*((?:0x[0-9a-fA-F]+\s*)+)", line)
        if not m:
            continue
        # One halfword per column-pair, eight per line, so the line's first word
        # is at the line's address and each word after it two bytes on. The
        # address is stepped once per word rather than per byte, because a word
        # IS the unit the monitor prints: stepping the other way makes all eight
        # words of a line land on the same two cells, and the row collapses to
        # the last one.
        addr = int(m.group(1), 16)
        for word in m.group(2).split():
            if not re.fullmatch(r"0x[0-9a-fA-F]+", word):
                continue
            # One halfword is two cells, so eight halfwords are sixteen bytes and
            # the address advances by 16 for each word on the line.
            #
            # The value stored per address is the byte, not the halfword. Storing
            # int(word, 16) whole and then reading cells[off] gives the low byte of
            # the first halfword for every cell, and cells[off + 1] gives that same
            # low byte again - so the character is right and the attribute is a
            # copy of it. Attribute 0x65 is not 0, so cells survive the "has this
            # been written" test, and the row decodes to the right text: which is
            # another way this reader could have reported a working console as
            # working for the wrong reason.
            #
            # And the address has to advance per word. Every word on a line is at
            # a different address, two bytes further along than the last: a halfword
            # is two bytes and there are eight per line. Reading all eight at the
            # line's address instead - which is what indexing by i alone does -
            # overwrites the same two cells eight times, so a full line of text
            # collapses to the last two characters of it and the rest of the screen
            # reads as blank.
            val = int(word, 16)
            # Low byte is the character, high byte is the attribute: 0x0765 is
            # 'e' on a grey background, not a control character on a 'v'.
            # Backwards puts the attribute at zero for every cell and the
            # "has this cell been written" test below throws the screen away.
            if BASE <= addr < BASE + SIZE:
                cells[addr - BASE] = val & 0xFF
            if BASE <= addr + 1 < BASE + SIZE:
                cells[addr + 1 - BASE] = (val >> 8) & 0xFF
            addr += 2

    rows = []
    for row in range(ROWS):
        out = []
        for col in range(COLS):
            off = row * COLS * 2 + col * 2
            ch = cells.get(off, 0)
            attr = cells.get(off + 1, 0)
            # The attribute byte decides whether a cell has ever been written.
            # On QEMU's std VGA a buffer nothing has touched is 0xFF throughout,
            # and without this test all 2000 cells count as characters and the
            # screen reads as 2000 replacement characters - which hides the text
            # that is there rather than reporting its absence.
            out.append(chr(ch) if attr and 32 <= ch < 127 else " ")
        rows.append("".join(out).rstrip())
    return [r for r in rows if r.strip()]


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: live-boot-vga.py MONITOR_SOCKET\n")
        return 2
    mon = Monitor(sys.argv[1])
    dump = mon.command("xp /2000xh 0x%x" % BASE)
    if "nknown command" in dump:
        sys.stderr.write("live-boot-vga: this monitor does not know xp:\n%s\n"
                         % dump.strip()[:300])
        return 2

    rows = read_text_buffer(dump)
    if not rows:
        sys.stderr.write(
            "live-boot-vga: the VGA text buffer at 0x%x holds no text.\n"
            "\n"
            "Two quite different things look like this, and the difference matters:\n"
            "\n"
            "  vgacon is bound and nothing was written to tty1.  Check with\n"
            "      cat /sys/class/vtconsole/vtcon0/name\n"
            "    which should say (S) VGA+.  If it says dummy device then the kernel\n"
            "    had no console driver at all, and no bootloader setting will fix that.\n"
            "\n"
            "  vgacon is not bound, and a framebuffer console has it instead.  Then\n"
            "    the text is not in this buffer at all and this reader cannot see it.\n"
            "    base has no X client, so nothing should be loading a DRM driver; if\n"
            "    one is, that is worth knowing.\n" % BASE)
        return 1

    print("\n".join(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
