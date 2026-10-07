#!/usr/bin/env python3
"""rotate_toor v1.3 -- 设备 toor 口令轮换 (只读 rootfs 下的 /etc/shadow 覆盖通道)

背景: rootfs(squashfs) 只读, /etc/shadow 无法直接编辑; rc.extend v1.9 起在开机时
把 /data/gw/shadow.override bind 到 /etc/shadow (本工具亦即时 bind, 不等重启)。

流程:
  1. 用户先把【新口令】写入 _local/secrets/device_local.py 的 TOOR_PASS
     (或 --prompt-new 改为交互输入, 但须与 device_local 最终一致, 否则工具链断)。
  2. 本工具交互询问【旧口令】(getpass, 不进 argv/命令行历史/本脚本日志)。
  3. 取回当前 /etc/shadow -> 仅替换 toor 行哈希(SHA-512, $6$) -> (可选 --lock-root
     同时锁死厂商 root 口令行) -> 本地校验(行数/字段数不变) -> 经同一 SSH 会话直投
     (deploy.put 同款协议: rm tmp -> cat -> md5 门禁 -> 原子 mv -> 复核, 3 重试) -> 即时 bind。
  4. 验证: 新口令可登录, 旧口令被拒; 已有会话不受影响。

用法:
  python tools/rotate_toor.py                # 新口令读 device_local.TOOR_PASS
  python tools/rotate_toor.py --lock-root    # 同时锁死厂商 root 口令(推荐, 审计P0-5)
  python tools/rotate_toor.py --prompt-new   # 新口令也交互输入(不读 device_local)

注意: 轮换不等同泄露闭环 -- 旧口令仍存于私有仓文件与 git 历史, 需另行清史。
"""
import os
import re
import sys
import getpass
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.abspath(os.environ.get("LG_SECRETS_DIR") or os.path.join(
    os.path.dirname(HERE), "..", "_local", "secrets")))
try:
    import device_local as D
except ImportError:
    D = None

import paramiko  # noqa: E402
import lgssh     # noqa: E402 (v1.3: 主机密钥指纹钉死复用)


def load_new_pass(prompt_mode):
    if prompt_mode:
        p1 = getpass.getpass("新 toor 口令: ")
        p2 = getpass.getpass("再输一遍: ")
        if p1 != p2 or not p1:
            sys.exit("FAIL: 两次输入不一致或为空")
        return p1
    pw = os.environ.get("LG_TOOR_PASS") or getattr(D, "TOOR_PASS", "")
    if not pw:
        sys.exit("FAIL: device_local.py 无 TOOR_PASS (或先用 --prompt-new)")
    return pw


def gen_hash(password):
    """SHA-512 crypt via openssl -stdin: 口令不进 argv/ps。"""
    salt = os.urandom(4).hex()  # 8 hex chars
    h = subprocess.run(
        ["openssl", "passwd", "-6", "-salt", salt, "-stdin"],
        input=password.encode(), capture_output=True, check=True)
    out = h.stdout.decode().strip()
    if not out.startswith("$6$"):
        sys.exit("FAIL: openssl 哈希输出异常")
    return out


def ssh_client(host, user, pw):
    c = paramiko.SSHClient()
    # v1.3: 指纹钉死(lgssh.PinPolicy); 未配置 HOST_KEY_FP 时兼容旧行为
    c.set_missing_host_key_policy(lgssh.PinPolicy() if lgssh.PIN else paramiko.AutoAddPolicy())
    c.connect(host, port=22, username=user, password=pw, timeout=10,
              allow_agent=False, look_for_keys=False)
    return c


def run(c, cmd):
    _, out, err = c.exec_command(cmd, timeout=30)
    o = out.read().decode("utf-8", "replace")
    e = err.read().decode("utf-8", "replace")
    return o + (("\n[stderr] " + e) if e.strip() else "")


def main():
    lock_root = "--lock-root" in sys.argv
    prompt_new = "--prompt-new" in sys.argv

    new_pass = load_new_pass(prompt_new)
    old_pass = getpass.getpass("当前(旧) toor 口令: ")
    if old_pass == new_pass:
        sys.exit("FAIL: 新旧口令相同, 无需轮换")

    host = os.environ.get("LG_HOST") or getattr(D, "HOST", "192.168.9.1")
    user = os.environ.get("LG_TOOR_USER") or getattr(D, "TOOR_USER", "toor")

    # 1) 取回当前 shadow (旧口令认证)
    c = ssh_client(host, user, old_pass)
    try:
        shadow = run(c, "cat /etc/shadow")
        if "toor:" not in shadow:
            sys.exit("FAIL: 设备 /etc/shadow 无 toor 条目")
        old_lines = shadow.rstrip("\n").splitlines()

        # 2) 构造 override: 仅改目标字段, 行数/字段结构不变
        new_hash = gen_hash(new_pass)
        out_lines, hit_toor, hit_root = [], 0, 0
        for ln in old_lines:
            f = ln.split(":")
            if f[0] == "toor":
                f[1] = new_hash
                hit_toor += 1
            elif lock_root and f[0] == "root":
                f[1] = "!"  # 锁死: 口令认证永久拒绝(root 亦无其他消费者)
                hit_root += 1
            out_lines.append(":".join(f))
        if hit_toor != 1:
            sys.exit(f"FAIL: toor 行数异常 ({hit_toor})")
        if len(out_lines) != len(old_lines):
            sys.exit("FAIL: 行数变化, 拒绝写入")

        payload = ("\n".join(out_lines) + "\n").encode()
        print(f"override 构造完成: {len(out_lines)} 行 (toor 哈希已换"
              + (", root 已锁死" if lock_root else "") + ")")

        # 3) 送达 — deploy.put 同款协议, 经本会话直投 (v1.2: 子进程 deploy 方式在
        #    轮换窗口期不可靠 — deploy 的 device_local 凭证链指向新口令而设备仍
        #    旧口令; 本会话已实证可连(取回 shadow), 直投协议不变:
        #    rm tmp -> cat > tmp -> md5 门禁 -> 原子 mv -> 复核, 3 次重试)
        import hashlib
        want = hashlib.md5(payload).hexdigest()
        remote = "/data/gw/shadow.override"
        tmp = remote + ".putting"
        # v1.4(P3): 现役 override 先存档 .bak — rc.extend v2.1 的回退源
        print(run(c, "[ -f %s ] && cp -f %s %s.bak && echo BAK-SAVED || echo no-previous" % (remote, remote, remote)).strip())
        delivered = False
        for attempt in (1, 2, 3):
            run(c, "rm -f %s" % tmp)
            try:
                si, so, se = c.exec_command("cat > %s" % tmp, timeout=60)
                si.write(payload); si.flush(); si.channel.shutdown_write()
                rc = so.channel.recv_exit_status()
                if rc != 0:
                    print(f"  第{attempt}次: cat rc={rc}"); continue
                got = run(c, "md5sum %s" % tmp).split()
                if not got or got[0] != want:
                    print(f"  第{attempt}次: md5 不一致 ({got[0] if got else '空'})"); continue
                run(c, "chmod 600 %s && mv -f %s %s" % (tmp, tmp, remote))
                ok2 = run(c, "md5sum %s" % remote).split()
                if ok2 and ok2[0] == want:
                    delivered = True
                    break
                print(f"  第{attempt}次: mv 后复核失败")
            except Exception as e:
                print(f"  第{attempt}次: 通道异常 {e!r}")
        run(c, "rm -f %s" % tmp)
        if not delivered:
            sys.exit("FAIL: 3 次投递失败 — 设备 shadow 未被触碰, 旧口令会话仍可用")

        # 4) 即时 bind (不等重启; 与 rc.extend v1.9 幂等守卫一致)
        print(run(c, "chmod 600 /data/gw/shadow.override; "
                     "grep -q ' /etc/shadow ' /proc/mounts || "
                     "mount --bind /data/gw/shadow.override /etc/shadow; "
                     "grep -q ' /etc/shadow ' /proc/mounts && echo BIND-LIVE"))
        c.close()

        # 5) 验证: 新口令通, 旧口令拒
        c2 = ssh_client(host, user, new_pass)
        print("新口令登录: " + run(c2, "id").strip())
        c2.close()
        try:
            ssh_client(host, user, old_pass)
            print("!! 旧口令仍可登录 -- 轮换未生效, 请勿结束会话排查")
            sys.exit(1)
        except paramiko.ssh_exception.AuthenticationException:
            print("旧口令已拒: OK")
        print("\n轮换完成。后续: 1) 重启一次验证 rc.extend v1.9 开机 bind; "
              "2) 私有仓旧口令/哈希仍在文件与历史中, 需另行清史。")
    finally:
        try:
            c.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
