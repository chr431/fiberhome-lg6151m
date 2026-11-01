#!/usr/bin/env python3
"""devop.py -- 设备变更操作的唯一入口（锁 + 演练窗口 一步到位）

背景：2026-11-01 一天内两个子代理各犯 3 次「未持锁写设备」或「演练未开窗」，靠人记不可靠。
本工具把两件事合成一步：acquire 锁 -> (可选) 开 drills 窗口 -> 执行命令 -> 关窗口 -> 释放锁。
任何一步失败都会拒绝执行命令，并在输出里打 ACQUIRED/RELEASED 供验收抽查。

用法：
  # 只写设备、不中断服务（部署/改文件）
  python _local/devop.py --owner NAME --purpose "push xxx" -- <cmd...>

  # 会中断服务的演练（自动开/关 drills 窗口）
  python _local/devop.py --owner NAME --purpose "kill v3httpd x5" \
      --drill-target v3httpd --drill-note "R4-A recovery latency drill" -- <cmd...>

退出码：0=成功 2=锁被占/窗口冲突 3=参数错误 其它=命令自身的退出码
"""
import argparse
import os
import subprocess
import sys

# 路径约定（v2, 2026-11-01 迁入仓库）：
#   工具本体在 lg6151m-public/tools/（版本控制），**运行态**仍写 _local/（不入仓）：
#   PROJ = dirname(dirname(HERE)) = 项目根；LOCAL = PROJ/_local
HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(os.path.dirname(HERE))
LOCAL = os.environ.get("LG_LOCAL_DIR") or os.path.join(PROJ, "_local")
LOCK = os.path.join(HERE, "device_lock.py")
DRILL = os.path.join(HERE, "drill.py")


def run_tool(args):
    return subprocess.call([sys.executable] + args)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--owner", required=True)
    ap.add_argument("--purpose", default="")
    ap.add_argument("--wait", type=int, default=120,
                    help="lock acquire 的排队等待秒数（默认 120；0=立刻 REFUSED）")
    ap.add_argument("--drill-target", default="")
    ap.add_argument("--drill-kind", default="drill-manual")
    ap.add_argument("--drill-note", default="")
    ap.add_argument("argv", nargs=argparse.REMAINDER)
    ns = ap.parse_args()

    argv = list(ns.argv)
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        print("devop: missing command after --")
        return 3

    rc = run_tool([LOCK, "acquire", "--owner", ns.owner,
                   "--purpose", ns.purpose or " ".join(argv[:2]), "--wait", str(ns.wait)])
    if rc != 0:
        print("devop: REFUSED (lock) rc=%d -- command NOT executed" % rc)
        return 2

    drill_open = False
    try:
        if ns.drill_target:
            rc = run_tool([DRILL, "start", "--owner", ns.owner,
                           "--kind", ns.drill_kind, "--target", ns.drill_target,
                           "--note", ns.drill_note or ns.purpose or ns.drill_target])
            if rc != 0:
                print("devop: REFUSED (drill window) rc=%d -- command NOT executed" % rc)
                return 2
            drill_open = True
        return subprocess.call(argv)
    finally:
        if drill_open:
            run_tool([DRILL, "stop", "--owner", ns.owner])
        run_tool([LOCK, "release", "--owner", ns.owner])


if __name__ == "__main__":
    sys.exit(main())
