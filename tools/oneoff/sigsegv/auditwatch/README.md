# auditwatch -- audit netlink 客户端 + 正对照触发器(A2,离线构建)

> **状态:已上机（A2 首窗 2026-11-02，C-189）：30 min、EXIT/ALWAYS、掩码
> {process_vm_readv=270, process_vm_writev=271}、key=h21vm；正对照 3/3
> （vmpoke process_vm_writev 行入 kmsg+kmsglog），覆盖集内非 vmpoke 调用 0 条
> （lost=0）。边界：只覆盖 audit-on 之后 fork 的进程（先已存在的长驻守护不可见）；
> ptrace(117) 按设计未纳入本窗（独占 ptrace owner 刷屏 + printk 限速）。
> 本目录为 oneoff 取证仪器,不注册、
> 不常驻。目标:回答 SIGSEGV 调查 H2-1 —— "是否存在用户态进程经
> process_vm_writev / process_vm_readv / ptrace 写别的进程内存"。
> 设备事实:内核 AUDIT=y + AUDITSYSCALL=y,无 auditd/auditctl,
> root 有 CAP_AUDIT_CONTROL。事件将以 `audit(...)` 行进 kmsg
> (无 auditd 时 kauditd 对每条记录 printk,见 kernel/audit.c
> kauditd_hold_skb -> kauditd_printk_skb -> pr_notice "type=%d ...")。

## 1. 文件

| 文件 | 作用 |
|---|---|
| `audit_const.h` | 全部常量,逐条手工抄自 `_local/legacy/linux-5.15.134`(与设备内核同版本),每条注明源文件行号;**禁止**改用宿主/目标 libc 的 kernel 头 |
| `auditpoke.c` | auditctl 替代品:NETLINK_AUDIT 客户端,子命令 `on/off/status/add/list/del/selftest` |
| `vmpoke.c` | 正对照触发器:fork 子进程后对其栈做 N 次 process_vm_writev(32B)+ 一次 ptrace(POKEDATA),并验证写入落位 |
| `build.sh` | zig cc 离线构建(同 build_procmatch.sh 工具链家族) |
| `auditpoke`、`vmpoke` | 已产出的静态 aarch64-linux-musl 二进制(38872/28256 字节) |
| `auditpoke-x86_64`、`vmpoke-x86_64` | WSL 冒烟用 x86-64 变体(设备不需要,可删) |
| `auditpoke_selftest_host` | 主机自测产物(Windows 原生 exe,构建时顺带生成) |

规则内容:add 会装 **list=EXIT / action=ALWAYS / arch=AUDIT_ARCH_AARCH64(0xC00000B7) /
syscall 掩码 {ptrace=117, process_vm_readv=270, process_vm_writev=271} /
filterkey="h21vm"**(数值来源:`include/uapi/asm-generic/unistd.h`:385/729/731;
`include/uapi/linux/audit.h`:383 + `include/uapi/linux/elf-em.h`:46)。
一条规则盖三个 syscall;ptrace 的具体请求(PEEK/POKE/ATTACH/SETREGSET)看记录里的
`a0=`(见 §5 判读表)。

## 2. 构建与自检(已完成的部分)

```sh
cd tools/oneoff/sigsegv/auditwatch && sh build.sh          # aarch64 对 + 主机自测
sh build.sh x86_64                                          # WSL 冒烟变体
sh build.sh selftest                                        # 仅主机自测
```

- 主机自测(Windows 原生编译运行):**15/15 PASS** —— nlmsghdr/audit_rule_data
  布局偏移、掩码位、filterkey 打包、线长对齐,全部与 5.15.134 头文件核对值断言一致。
- WSL x86-64 冒烟(WSL2 内核 6.18,CONFIG_AUDIT=y):
  - 协议回环:status/add/list 均收到内核 **EPERM** 回包并被正确解码——WSL2 的
    distro 跑在非 init pid namespace,而内核对 AUDIT_SET/ADD_RULE/LIST_RULES
    硬性要求 init pid ns(kernel/audit.c audit_netlink_ok)。**这是 WSL 的限制,
    不是代码缺陷**;设备 toor 在 init pid ns,不受此限。故"规则真的被接受 +
    真的出 kmsg 行"只能在设备上验证。
  - 触发器:vmpoke 3/3 次 process_vm_writev(32B→子进程栈)+ ptrace
    ATTACH/POKEDATA/DETACH 全部落位、子进程校验通过、退出码正确
    (1=usage、2=内核拒绝,曾因宿主 shell 展开 `$?` 误读为 0,已用脚本文件复核)。
- **离线无法覆盖**:AUDIT_ADD_RULE 真实接受、`audit(...)` kmsg 行真实产生、
  设备 5.15.134 与 6.18 的行为差异。全部留给上机窗口。

## 3. 上机部署(设备线空闲时)

```sh
# PC 侧(公开仓根目录,Git Bash;必须 MSYS_NO_PATHCONV=1)
MSYS_NO_PATHCONV=1 python tools/deploy.py put \
    tools/oneoff/sigsegv/auditwatch/auditpoke /data/gw/auditpoke
MSYS_NO_PATHCONV=1 python tools/deploy.py put \
    tools/oneoff/sigsegv/auditwatch/vmpoke  /data/gw/vmpoke
# put 不保留权限位(AGENTS 已知陷阱)——必须补:
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'chmod 755 /data/gw/auditpoke /data/gw/vmpoke'
MSYS_NO_PATHCONV=1 python tools/deploy.py doctor   # 复核
```

一次性(不落盘)备选:直接 `lgssh.py` 前台跑,二进制放 /tmp 亦可(tmpfs 重启自清,
更符合"用完即撤")。

## 4. 验证序列(上机后第一件事)

```sh
/data/gw/auditpoke status        # 预期: audit_enabled=0 (off) ...   (rc=0)
/data/gw/auditpoke on            # 预期: audit enabled=1 (rc=0)
/data/gw/auditpoke add           # 预期: rule added (rc=0); 重复 add 预期 EEXIST(rc=2,无害)
/data/gw/auditpoke list          # 预期: 1 rule(s), list=EXIT action=ALWAYS ... key="h21vm"
/data/gw/vmpoke 3 300            # 预期: 3/3 verified + POKEDATA OK (rc=0)
dmesg | tail -50                 # 判据见 §5;console 若 deaf 用设备侧 kmsg 落盘组件
/data/gw/auditpoke status        # 看 lost= 是否增长(丢记录则需调 backlog)
```

**必须先 `on` 再 `add` 之外的顺序要点**:`on` 与 `add` 顺序可换,但 vmpoke 必须在
两者之后。若 kmsg 无 `type=1300` 行:① `status` 确认 enabled=1;② `list` 确认规则在;
③ 换 `cat /dev/kmsg` 或设备侧 kmsg 落盘组件(console ratelimit 可能压掉部分行,
vmpoke 默认 300ms 间隔即为此留余量)。

## 5. kmsg 判读

命中行形如(无 auditd,kauditd printk,`type=1300` = AUDIT_SYSCALL 记录):

```
type=1300 audit(1191234567.123:456): arch=c00000b7 syscall=271 success=yes exit=32
  a0=... a1=... a2=... a3=... items=0 ppid=... pid=... auid=... uid=0 gid=0
  ... comm="xxx" exe="..." key="h21vm"     (key 是我们规则打的标)
```

| 字段 | 读法 |
|---|---|
| `syscall=271/270` | process_vm_writev / readv;a0=目标 pid,a1=本地 iovec,a2=liovcnt,a3=远端 iovec |
| `syscall=117` | ptrace;**a0=请求码**:2=PEEKDATA(读) 5=POKEDATA(写) 16=ATTACH 17=DETACH 0x4204=GETREGSET 0x4205=SETREGSET(改寄存器,aarch64 无 GETREGS/SETREGS) |
| `success=yes/no` + `exit=` | 返回值;no+EPERM = 试了但被拒(同样算"存在写者"的证据) |
| `comm=` / `exe=` / `pid=` / `ppid=` | 直接点名;看 ppid 定位父守护 |
| `key="h21vm"` | 区分本仪器规则与其他来源 |

## 6. 观察窗口与"无跨进程写者"的判读语义

**这是事件驱动取证,不是快照取证**。规则装好后,覆盖集合内每一次命中 syscall 都会
在发生当刻产生记录——不存在 strace 类"采样间隙"(对不在 strace 下的进程,
strace 快照法漏检≈全漏)。因此:

- **窗口建议**:≥ 24h 且覆盖一个完整业务周期(含 04:00 前后——注意 reboot_sched.sh
  出厂每日 04:00 定时重启,**重启会清空 enabled 与全部规则**,重启后必须重新
  `on+add`,见 §8)。若调查目标与高负载时段相关,叠加一个高峰窗口。
- **阳性即结论**:窗口内任一条 `syscall=271 success=yes`(或 117/a0=5 等)且
  comm 不是 vmpoke 自己 = H2-1 直接证据,记录 pid/ppid/exe 与 ne_events 时间轴对齐。
- **阴性 = 分层陈述**,必须写成:"在窗口 T 内、在**覆盖集合**(见下盲区 ①②)中,
  零次 ptrace/process_vm_* 调用被记录(N=0 条;含被 EPERM 拒绝的尝试)"。
  它**不能**外推到:窗口外的时刻、覆盖集合外的进程、以及下列盲区通道。

**已知盲区(写结论时必须带上)**:

1. **fork 早于 `on` 的进程完全不可见**。audit 上下文只在 fork 时分配
   (kernel/fork.c copy_process -> audit_alloc),且要求 audit_ever_enabled
   已置位——开机即存在的长驻守护在 `on` 之前 fork,则整窗口零覆盖。
   补法:(a) `on+add` 后重启设备/重启嫌疑进程再观察;(b) 要全覆盖须开机早期
   注入 `on`(rcS/watchdog 挂钩,属设备线集成决策,不在本 oneoff 范围)。
2. **/proc/pid/mem 的 write() 路径**:对 procfs 文件的 write 走 vfs_write ->
   mem_rw,syscall 层只表现为普通 `write(2)`——本规则(117/270/271)抓不到,
   而 audit 的路径过滤(watch/dir)依赖 inotify,不支持 procfs。
   补法(建议列为 A2b,kptr_restrict=0 可行):ftrace kprobe 探
   `mem_rw`(fs/proc/base.c,static,kallsyms 可见)+ 抓栈点名调用者;
   或对短期嫌疑清单用 strace -f -e write -y 定向(快照语义,只作旁证)。
3. **printk_ratelimit**:kmsg 行经 ratelimit,瞬时爆发(>10 行/5s 量级)会压行。
   低频真实事件不受影响;`status` 的 lost= 与 CONFIG_CHANGE 行可交叉核对。
4. **KAUDIT 无 auditd 的 hold 队列**:记录 printk 后仍进 hold 队列
   (audit_backlog_limit 默认 64),不影响 kmsg 取证,仅提示有上限。
5. 内核态写者(EL1/uaccess)不经 syscall,本仪器设计上不可见(那是 H3/E4 线)。

## 7. 撤销

```sh
/data/gw/auditpoke del            # 预期: rule deleted; 规则不在时 ENOENT(rc=2,无害)
/data/gw/auditpoke off            # audit_enabled=0,记录停发(规则本应已删)
/data/gw/auditpoke list           # 预期: 0 rule(s)
/data/gw/auditpoke status         # 预期: audit_enabled=0 (off)
# PC 侧移除二进制(若落了 /data/gw):
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'rm -f /data/gw/auditpoke /data/gw/vmpoke'
# /tmp 方案重启自清,无需 rm
```

**红线**:绝不 `auditpoke on 2`(enabled=LOCKED,重启前不可逆,工具已硬拒)。
撤销顺序 del → off:先删规则再关开关,避免"关了开关但规则残留"的歧义状态。

## 8. 设备侧注意

- 04:00 定时重启(reboot_sched.sh)后 enabled/规则全清:长窗口观察要么接受
  每日重装,要么窗口内避开 04:00,要么(设备线决策)开机钩子自动 `on+add`。
- 串口会话里跑 vmpoke:子进程校验信息走 stderr,长输出会被串口吃字符——
  建议输出重定向到 /tmp 文件再 cat(vmpoke 输出 <30 行,风险低)。
- 每次运行按目录纪律记录:日期、boot id、uptime、二进制 md5、dmesg 原文。
  (aarch64 md5:auditpoke 47f3723d18d677060b37bf6ab2cd7d63,
  vmpoke b7536e4ef998525e86273bff3f749434,以重新构建为准。)

## 9. 纪律

- 本目录零涉密字样,中性命名;未 commit,待验收。
- 设备未验证前,其阴性不得写入 01_CLAIMS.tsv 的 E2 以上。
