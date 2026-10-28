#!/usr/bin/env python3
"""zigcc.py -- launch zig with a complete Windows profile environment.

Why: zig resolves its cache through the Windows profile (LOCALAPPDATA/TMP).  A
normal interactive shell inherits those, but scrubbed/non-interactive shells and
MSYS shells that do not propagate exported variables leave zig with none -> every
compile fails with "AppDataDirUnavailable".  Python is a native process, so the
environment set here does reach zig.  Use it as CC for make-driven builds:

    CC="python tools/zigcc.py cc -target aarch64-linux-musl" make ...

The zig path can be overridden with ZIG_REAL.
"""
import os
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve()
repo = here.parent.parent                      # <repo>/tools/zigcc.py -> <repo>
zig = os.environ.get("ZIG_REAL") or str(
    repo.parent / "_local" / "toolchains" /
    "zig-windows-x86_64-0.13.0" / "zig.exe")

local = os.environ.get("LOCALAPPDATA") or r"C:\Users\Eric Chen\AppData\Local"
os.environ.update({
    "LOCALAPPDATA": local,
    "APPDATA": os.environ.get("APPDATA") or r"C:\Users\Eric Chen\AppData\Roaming",
    "USERPROFILE": os.environ.get("USERPROFILE") or r"C:\Users\Eric Chen",
    "TMP": os.environ.get("TMP") or local + r"\Temp",
    "TEMP": os.environ.get("TEMP") or local + r"\Temp",
})
# zig's global cache under a profile path containing a space has been seen to
# fail its temp-file cleanup ("failed to delete ... FileNotFound"); pin both
# caches to a space-free repository path.
_tc = repo.parent / "_local" / "toolchains"
os.environ.setdefault("ZIG_GLOBAL_CACHE_DIR", str(_tc / "zigcache-global"))
os.environ.setdefault("ZIG_LOCAL_CACHE_DIR", str(_tc / "zigcache"))
argv = []
skip = False
for a in sys.argv[1:]:
    if skip:
        skip = False
        continue
    if a == "-Wp,-MMD,":
        skip = True
        continue
    if a.startswith("-Wp,-MMD,"):
        continue          # kbuild dependency file: zig cannot consume this form
    argv.append(a)
sys.exit(subprocess.call([zig] + argv))
