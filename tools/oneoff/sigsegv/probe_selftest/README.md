# 探针正对照（PF / cfu / uw）

> 目的：把“0 命中”从“仪器没工作”里分开。每个用例都必须先跑一次**故意触发**，看到预期日志，才允许把对应探针的阴性写进 `01_CLAIMS.tsv`。

## 1. 构建

模块（复用现有 freestanding 链）：

```bash
wsl bash /mnt/d/Repo/lg6151m-project/tmpfiles/an4/build.sh probe_selftest
```

用户态：

```bash
python tools/zigcc.py cc -target aarch64-linux-musl -static -O2 \
  -o tools/oneoff/sigsegv/probe_selftest/probe_selftest_user \
  tools/oneoff/sigsegv/probe_selftest/probe_selftest_user.c
```

## 2. 部署

```bash
MSYS_NO_PATHCONV=1 python tools/deploy.py put tools/oneoff/sigsegv/probe_selftest/probe_selftest.ko /data/repro/probe_selftest.ko
MSYS_NO_PATHCONV=1 python tools/deploy.py put tools/oneoff/sigsegv/probe_selftest/probe_selftest_user /data/repro/probe_selftest_user
# put 不保留执行位：
ssh toor@192.168.9.1 'chmod 755 /data/repro/probe_selftest_user'
```

## 3. 用例

先加载 `cth.ko`（`hook_pf=1 pf_lo=... pf_hi=...` 或默认）与 `uw.ko`（`irq_only=1`）。

### 3.1 PF

```bash
insmod /data/repro/probe_selftest.ko
/data/repro/probe_selftest_user pf
dmesg | tail -20
```

预期：`cth: PF#... far=<va> ... KERNEL ...`。若没有，`cth_pf` 不可信，`vro` 的 0 PF 不能当证据。

### 3.2 cfu

```bash
/data/repro/probe_selftest_user cfu
dmesg | tail -20
```

预期：`cth: CFU-MISUSE#... dst(user)=<va> ...`。若没有，`cfu` 的 0 命中不能排除 `copy_from_user` 误用。

### 3.3 uw

```bash
/data/repro/probe_selftest_user uw
dmesg | tail -20
```

预期：`uw: HIT#... ENABLE site=... irq=1`。若没有，`uw` 的 0 命中不能排除 uaccess 窗口。

## 4. 记录

把每个用例的日期、设备 boot id、`dmesg` 原文、是否通过写进 `05_LOG/`；并在 `03_PROBES.md` 更新 P-14 状态。

## 5. 注意

- `pf` 用例需要用户页 `mprotect(PROT_READ)`；`copy_to_user` 会返回 `-EFAULT`，这是预期的。
- `cfu` 用例的 dst 是用户页；`copy_from_user` 会成功写入 32 字节。
- `uw` 用例在 hrtimer 回调里 `copy_to_user`；若当前 mm 不是该用户进程，会 `-EFAULT`，但 `uaccess_ttbr0_enable` 仍应触发 `uw_hook`。若没有，先检查 `uw.ko` 的 `irq_only`/`usp_lo/usp_hi` 过滤。
- 三个用例都是**故意**的异常路径；跑完 `rmmod probe_selftest`。
