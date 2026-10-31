#!/usr/bin/env python3
"""sshx.py -- thin SSH wrapper for the acceptance tooling (PC side).

Why not just call lgssh.py: the acceptance tools need (a) a long command timeout
(one fault injection runs 60-240s device-side inside a single exec), (b) the
ability to keep one connection for many commands, and (c) machine-readable
errors instead of a printed traceback.  lgssh.connect() already owns the
credential chain and the host-key pinning, so we reuse it verbatim rather than
duplicating a second credential path (project rule: one implementation).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PUB = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(PUB, "tools"))

import lgssh  # noqa: E402


class Dev:
    """One reusable SSH connection to the device."""

    def __init__(self):
        self.c = lgssh.connect()

    def run(self, cmd, timeout=120):
        """Run a command, return (rc, stdout+stderr text)."""
        try:
            out = lgssh.run(self.c, cmd, timeout=timeout)
        except Exception as e:  # socket/timeout: report, never mask
            return 255, "SSH_ERROR %s: %s" % (type(e).__name__, e)
        return 0, out

    def put_text(self, remote_path, text, timeout=60):
        """Write a text file on the device WITHOUT putting the content on any cmdline.

        Why a raw exec+stdin instead of SFTP: dropbear on this device has NO sftp
        subsystem (project rule: use deploy.py put for files), so paramiko's
        open_sftp() dies with "EOF during negotiation" -- verified live.

        Why at all: the fault-injection harness must not carry the target daemon
        path in its own /proc/<pid>/cmdline -- svc_lib.alive() falls back to
        `pgrep -f /data/gw/<script>`, so a harness shell that merely MENTIONS the
        path makes watchdog believe the (killed) daemon is still alive.
        Observed live 2026-11-01 00:05: ntp_keeper stayed dead 3+ min while
        watchdog reported ntp_keeper=0 (ok).
        """
        chan = self.c.get_transport().open_session(timeout=timeout)
        try:
            chan.settimeout(timeout)
            chan.exec_command("cat > %s" % remote_path)
            chan.sendall(text.encode("utf-8"))
            chan.shutdown_write()
            rc = chan.recv_exit_status()
        finally:
            try:
                chan.close()
            except Exception:
                pass
        return rc == 0

    def close(self):
        try:
            self.c.close()
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def main():
    if len(sys.argv) < 2:
        print("usage: sshx.py '<command>'")
        return 2
    with Dev() as d:
        rc, out = d.run(sys.argv[1], timeout=int(os.environ.get("SSH_TIMEOUT", "120")))
        sys.stdout.write(out)
        return rc


if __name__ == "__main__":
    sys.exit(main())
