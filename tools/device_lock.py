#!/usr/bin/env python3
"""device_lock.py v2 -- 单设备互斥锁（本项目所有代理共用）

v2 变更（2026-11-01，因 v1 陈旧判定缺陷导致 soak-qa/crash-root 撞车）：
  - v1 用锁目录 mtime 判陈旧，但长任务不会刷新 → 15min 后被误判陈旧并遭夺取。
  - v2：以 owner.json 的 mtime 作 last_seen；新增 touch / hold / run 自动心跳；
        touch 间隔默认 60s，STALE_SEC 默认 1800s（30min），留足余量。
  - 增加 stale 夺取留痕与"夺取前二次确认"（连续两次读到的 last_seen 相同才算真陈旧）。

用法:
  python _local/device_lock.py status
  python _local/device_lock.py acquire --owner NAME --purpose "text" [--wait SEC]
  python _local/device_lock.py touch   --owner NAME
  python _local/device_lock.py release --owner NAME
  python _local/device_lock.py run --owner NAME --purpose "text" -- <cmd...>
  python _local/device_lock.py hold --owner NAME --purpose "text" --minutes N   # 前台持锁 N 分钟并心跳

退出码: 0=成功 2=被他人持有 3=参数错误
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time

# 路径约定（v2, 2026-11-01 迁入仓库）：
#   工具本体在 lg6151m-public/tools/（版本控制），**运行态**仍写 _local/（不入仓）：
#   PROJ = dirname(dirname(HERE)) = 项目根；LOCAL = PROJ/_local
HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(os.path.dirname(HERE))
LOCAL = os.environ.get("LG_LOCAL_DIR") or os.path.join(PROJ, "_local")
LOCKDIR = os.path.join(LOCAL, "device.lock")
HISTORY = os.path.join(LOCAL, "device.lock.history.log")
OWNERF = os.path.join(LOCKDIR, "owner.json")
STALE_SEC = int(os.environ.get("DEVLOCK_STALE", "1800"))
HB_SEC = int(os.environ.get("DEVLOCK_HB", "60"))


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def read_owner():
    try:
        with open(OWNERF, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def last_seen_age():
    try:
        return time.time() - os.path.getmtime(OWNERF)
    except OSError:
        try:
            return time.time() - os.path.getmtime(LOCKDIR)
        except OSError:
            return 0.0


def hist(msg):
    try:
        with open(HISTORY, "a", encoding="utf-8") as f:
            f.write("%d %s %s\n" % (int(time.time()), now(), msg))
    except Exception:
        pass


def status():
    if not os.path.isdir(LOCKDIR):
        print("FREE")
        return 0
    o = read_owner() or {}
    print("HELD owner=%s purpose=%s last_seen=%ds stale=%s" % (
        o.get("owner", "?"), o.get("purpose", "?"), int(last_seen_age()),
        "YES" if last_seen_age() > STALE_SEC else "no"))
    return 0


def touch(owner=None):
    if not os.path.isdir(LOCKDIR):
        print("FREE (nothing to touch)")
        return 2
    o = read_owner() or {}
    if owner and o.get("owner") != owner:
        print("REFUSED lock held by %s" % o.get("owner", "?"))
        return 2
    o["last_seen"] = now()
    try:
        with open(OWNERF, "w", encoding="utf-8") as f:
            json.dump(o, f, ensure_ascii=False)
        os.utime(OWNERF, None)
        print("TOUCHED owner=%s" % o.get("owner"))
        return 0
    except Exception as e:
        print("TOUCH-FAIL %s" % e)
        return 2


class Heartbeat:
    def __init__(self, owner):
        self.owner = owner
        self.stop = threading.Event()
        self.t = threading.Thread(target=self._loop, daemon=True)

    def _loop(self):
        while not self.stop.wait(HB_SEC):
            try:
                touch(self.owner)
            except Exception:
                pass

    def __enter__(self):
        self.t.start()
        return self

    def __exit__(self, *a):
        self.stop.set()


def acquire(owner, purpose, wait):
    deadline = time.time() + max(0, wait)
    while True:
        try:
            os.mkdir(LOCKDIR)
        except FileExistsError:
            o = read_owner() or {}
            if o.get("owner") == owner:
                touch(owner)
                print("ALREADY_OWNED last_seen=%ds" % int(last_seen_age()))
                return 0
            age1 = last_seen_age()
            if age1 > STALE_SEC:
                time.sleep(3)                      # 二次确认：避免读到半写状态
                age2 = last_seen_age()
                if age2 > STALE_SEC:
                    hist("TAKEOVER by=%s from=%s last_seen=%ds purpose=%s" % (
                        owner, o.get("owner", "?"), int(age2), o.get("purpose", "?")))
                    shutil.rmtree(LOCKDIR, ignore_errors=True)
                    continue
            if time.time() >= deadline:
                print("BUSY owner=%s purpose=%s last_seen=%ds" % (
                    o.get("owner", "?"), o.get("purpose", "?"), int(last_seen_age())))
                return 2
            time.sleep(2)
            continue
        with open(OWNERF, "w", encoding="utf-8") as f:
            json.dump({"owner": owner, "purpose": purpose, "pid": os.getpid(),
                       "time": now(), "last_seen": now()}, f, ensure_ascii=False)
        print("ACQUIRED owner=%s" % owner)
        return 0


def release(owner):
    if not os.path.isdir(LOCKDIR):
        print("FREE (nothing to release)")
        return 0
    o = read_owner() or {}
    if o.get("owner") != owner:
        print("REFUSED lock held by %s" % o.get("owner", "?"))
        return 2
    shutil.rmtree(LOCKDIR, ignore_errors=True)
    print("RELEASED owner=%s" % owner)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    a = sub.add_parser("acquire"); a.add_argument("--owner", required=True)
    a.add_argument("--purpose", default=""); a.add_argument("--wait", type=int, default=0)
    t = sub.add_parser("touch"); t.add_argument("--owner", required=True)
    r = sub.add_parser("release"); r.add_argument("--owner", required=True)
    g = sub.add_parser("run"); g.add_argument("--owner", required=True)
    g.add_argument("--purpose", default=""); g.add_argument("--wait", type=int, default=0)
    g.add_argument("argv", nargs=argparse.REMAINDER)
    h = sub.add_parser("hold"); h.add_argument("--owner", required=True)
    h.add_argument("--purpose", default=""); h.add_argument("--minutes", type=float, default=30)
    ns = ap.parse_args()

    if ns.cmd == "status":
        return status()
    if ns.cmd == "acquire":
        return acquire(ns.owner, ns.purpose, ns.wait)
    if ns.cmd == "touch":
        return touch(ns.owner)
    if ns.cmd == "release":
        return release(ns.owner)
    if ns.cmd == "run":
        argv = list(ns.argv)
        if argv and argv[0] == "--":
            argv = argv[1:]
        if not argv:
            print("run: missing command after --"); return 3
        rc = acquire(ns.owner, ns.purpose or " ".join(argv[:2]), ns.wait)
        if rc != 0:
            return rc
        try:
            with Heartbeat(ns.owner):
                return subprocess.call(argv)
        finally:
            release(ns.owner)
    if ns.cmd == "hold":
        rc = acquire(ns.owner, ns.purpose, 0)
        if rc != 0:
            return rc
        end = time.time() + ns.minutes * 60
        try:
            while time.time() < end:
                time.sleep(min(HB_SEC, max(1, end - time.time())))
                touch(ns.owner)
        finally:
            release(ns.owner)
        return 0
    return 3


if __name__ == "__main__":
    sys.exit(main())
