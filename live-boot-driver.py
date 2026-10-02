#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 FreeLinX OS Project.
#
# live-boot-driver.py - talk to the FreeLinX guest over its serial console.
#
# Invoked by test-live-boot.sh as
#
#     live-boot-driver.py CONSOLE_SOCKET LOGFILE TIMEOUT
#
# and prints one line per check.  Exit status is 0 when every check passed.
#
# Why a socket and a marker loop, and not socat
# --------------------------------------------
# The guest's console is a login shell on /dev/ttyS0 - the same port the kernel
# and /init print to, since console= is last-one-wins - and the port this script
# is attached to.  Everything else on that line is a problem to solve rather
# than a race to lose: xorg, ntpd and mdevd all write to it, so "wait for the
# prompt" is not a thing that can be done by matching a prompt.  So no check
# waits for a prompt.
#
# Each check is one command line ending in
#
#     ; echo "<token> $?"
#
# and the result is whatever arrives between the previous token and this one.
# The shell prints the token itself, so a command that hangs, a command whose
# output interleaves with a service's, and a command that never runs at all are
# three different failures rather than one timeout.
#
# The one thing that is waited for is the console banner, because that is the
# readiness condition: flxconsole only prints it once it has opened a console,
# so a banner means the shell exists and is reading.

import os
import re
import socket
import sys
import time

CON = sys.argv[1]
LOG = sys.argv[2]
TIMEOUT = int(sys.argv[3]) if len(sys.argv) > 3 else 240

TOKEN = "@@FLX"
DEADLINE = time.time() + TIMEOUT

results = []


def log(text):
    with open(LOG, "a") as f:
        f.write(text)
        f.flush()


class Console:
    """A line-oriented view of the serial console.

    Everything read is kept in a buffer and a cursor is moved past each token as
    it is matched, so a check sees only what arrived after the previous one
    instead of the whole boot log.
    """

    def __init__(self, path):
        deadline = time.time() + 30
        last = None
        while time.time() < deadline:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError as exc:
                last = exc
                try:
                    self.sock.close()
                except OSError:
                    pass
                time.sleep(0.1)
        else:
            raise SystemExit("live-boot-driver: cannot connect to %s: %s" % (path, last))

        self.sock.settimeout(0.5)
        self.buf = ""
        self.cursor = 0

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            text = chunk.decode("utf-8", "replace").replace("\r", "")
            self.buf += text
            log(text)

    def wait_for(self, needle, timeout):
        """Wait for needle after the cursor; return the text before it."""
        end = time.time() + timeout
        while True:
            at = self.buf.find(needle, self.cursor)
            if at >= 0:
                text = self.buf[self.cursor:at]
                self.cursor = at + len(needle)
                return text
            if time.time() >= end:
                return None
            if time.time() >= DEADLINE:
                return None
            self.pump(0.5)

    def send(self, line):
        self.sock.sendall((line + "\n").encode())


# A counter of its own, not len(results).  Numbering tokens by how many results
# have been recorded makes the numbering depend on which earlier checks failed,
# so one failure renames every token after it and the log stops lining up with
# the checks - which is the one thing a log like this has to be trusted for.
counter = 0


def run(con, name, script, timeout=90):
    """Run script in the guest; return (output, status).

    The token is assembled by the shell from two quoted halves instead of being
    typed as one word:

        FLXT="@@F""LX6"; <script>; printf '%s %s\\n' "$FLXT" "$?"

    The terminal echoes what is typed, so a token sent as one word comes back
    off the wire before the shell has run anything, and every wait matches that
    echo instead of the result.  The echoed text - FLXT="@@F""LX6" - does not
    contain the token, while the shell's own output of "$FLXT" does.  This is
    why the check is not written as "wait for the prompt": there is no prompt to
    match, because xorg, ntpd and mdevd all write to this line as well.
    """
    global counter
    counter += 1
    token = "%s%d" % (TOKEN, counter)
    con.send('FLXT="%s""%s"; %s; printf "%%s %%s\\n" "$FLXT" "$?"'
             % (token[:3], token[3:], script))
    text = con.wait_for(token, timeout)
    if text is None:
        results.append((name, False, "no answer within %ds" % timeout))
        return "", None
    # The token is followed by the status, which arrives after the space.
    m = re.search(re.escape(token) + r" (\d+)", con.buf)
    status = int(m.group(1)) if m else None
    return text, status


def check(name, condition, detail=""):
    results.append((name, bool(condition), detail))
    return bool(condition)


con = Console(CON)
con.pump(1)

# The readiness condition: flxconsole has opened a console and the shell on it is
# reading.  Without the fix being tested this never appears, and every later
# check would time out rather than fail, which is why it is a check of its own.
banner = con.wait_for("login shell on /dev/ttyS0", 180)
check("serial console has a login shell", banner is not None,
      "flxconsole never opened /dev/ttyS0")

if banner is not None:
    # The banner on the tty itself is written before the one that goes to the
    # service's stdout, so the second line arrives after the string the wait
    # above stopped at.  Waited for separately rather than read out of the text
    # before the marker, which by construction ends at the first line.
    hint = con.wait_for("xsetup - install FreeLinX to disk", 30)
    check("the console banner names xsetup", hint is not None)

# Every console the kernel made gets a shell, and each is announced.  ttyS0 is
# the port this script is attached to; the others are announced on stdout,
# which /init leaves pointing at the kernel console, so they are visible here
# without a second connection.
for tty in ("/dev/tty1", "/dev/tty2"):
    seen = con.wait_for("login shell on %s" % tty, 5)
    check("flxconsole also opened %s" % tty, seen is not None)

# Quiet the terminal too, so the log is the answer rather than the answer with
# every question in it.  Nothing above depends on this working: run() builds its
# markers so that the echo cannot match them either way.
con.send("stty -echo 2>/dev/null")
con.pump(2.0)

# Give the rest of the boot - mdevd, the medium scan - a moment.  This is a fixed
# sleep rather than a wait for a condition because there is no single condition
# for "the boot has finished"; every check below is written to be true whenever
# it becomes true, and to fail with its own message when it never does.
con.pump(20)

# --- the console itself ------------------------------------------------------

out, _ = run(con, "TERM", "sh -c 'echo TERM=$TERM'", 30)
m = re.search(r"TERM=(\S+)", out)
term = m.group(1) if m else ""
check("TERM on the serial console is not the xterm-256color it used to force",
      term not in ("xterm-256color", ""), "TERM=%r" % term)

out, st = run(con, "prompt", "echo READY-$(id -u)", 30)
check("the shell is interactive and runs commands", st == 0 and "READY-0" in out,
      "status=%r out=%r" % (st, out.strip()[:200]))

# --- the medium --------------------------------------------------------------

out, st = run(con, "medium mounted", "grep ' /media/flx ' /proc/mounts", 30)
check("the medium this system booted from is at /media/flx", st == 0,
      (out.strip() or "not in /proc/mounts")[:300])

out, st = run(con, "medium ro", "grep ' /media/flx ' /proc/mounts | grep -c ' ro,'", 30)
# The count is the last line before the marker; the echoed command is in the
# same capture and is not the answer.
last = [l for l in (out or "").splitlines() if l.strip()]
check("the medium is mounted read-only", st == 0 and last and last[-1].strip() == "1",
      "mount line: %r" % (last[-1] if last else out)[:300])

out, st = run(con, "installer on medium", "test -x /media/flx/installer/xsetup", 30)
check("the installer is on the medium at /installer/xsetup", st == 0)

out, st = run(con, "installer steps",
              "ls /media/flx/installer/xsetup.d/*.sh | wc -l", 30)
steps = out.strip().split()[-1] if out.strip() else "0"
check("the medium carries the installer's steps", st == 0 and steps.isdigit() and int(steps) > 0,
      "%s step files" % steps)

# --- xsetup on PATH ----------------------------------------------------------

out, st = run(con, "xsetup on PATH", "command -v xsetup", 30)
path = out.strip().split()[-1] if out.strip() else ""
check("xsetup is a command in the running system", st == 0 and path == "/usr/sbin/xsetup",
      "command -v xsetup -> %r" % path)

out, st = run(con, "xsetup executable", "test -x /usr/sbin/xsetup", 30)
check("/usr/sbin/xsetup is executable", st == 0)

# --list prints the steps and exits, so it proves the hand-off from /usr/sbin/xsetup
# to the copy in /media/flx/installer without starting an install.  A no-argument
# run would prove the same thing and then ask twelve questions.
out, st = run(con, "xsetup reaches installer", "xsetup --list 2>&1", 60)
check("xsetup runs the installer from the medium",
      st == 0 and "setup-disk" in (out or ""),
      "status=%r output: %r" % (st, (out or "").strip()[:300]))

# --- the service that gives the prompt ---------------------------------------

out, st = run(con, "shell service", "sv status /var/service/shell 2>&1", 30)
check("the shell service is supervised by runit and up",
      st == 0 and "run:" in (out or ""), "sv status: %r" % (out or "").strip()[:300])

# --- report ------------------------------------------------------------------

print()
failed = 0
for name, good, detail in results:
    if good:
        print("  ok    %s" % name)
    else:
        failed += 1
        print("  FAIL  %s" % name)
        if detail:
            for line in str(detail).splitlines():
                print("          %s" % line)

sys.exit(1 if failed else 0)
