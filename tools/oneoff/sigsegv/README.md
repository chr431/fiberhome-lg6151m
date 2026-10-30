# SIGSEGV 调查仪器（oneoff）

> 本目录是 `tools/oneoff/` 下的取证/分析仪器，**不注册、不部署为常驻资产**。
> 当前结论与方法见 [docs/SIGSEGV/](../../../docs/SIGSEGV/README.md)。
> 状态：本地验证 / 设备待验证，逐项标注。

## 1. 离线分类（已本地验证）

| 工具 | 输入 | 用法 | 验证 |
|---|---|---|---|
| `va_scan.py` | 16KB 栈转储 + v3 日志 | `python va_scan.py --strict` | 106 份：71 A0B2 / 32 B0A2 / 3 other；`--legacy` 复现 71/35 |
| `core_scan.py` | 完整 ELF core | `python core_scan.py --strict-an2` | 6 份 an2：5 A0B2 + 1 B0A2；`pf.core` A0B2；`sh.core` n/a + 2 候选 |
| `natural_scan.py` | `vsurv4` h4 / `stackdump` sd | `python natural_scan.py --format h4 ...` / `--format sd ...` | h4 host 文件通过；sd host 文件通过（无 .hdr 时 x2/addr 为空） |
| `claims_check.py` | `docs/SIGSEGV/01_CLAIMS.tsv` | `python claims_check.py` | 32 条/32 id/19 active/4 retracted，OK |

依赖：`core_scan.py`/`natural_scan.py` 的 `.hdr` 解析需要 `pyelftools`；纯 h4/sd 不需要。

## 2. 设备侧仪器（已编译，设备待验证）

| 文件 | 作用 | 构建 | 状态 |
|---|---|---|---|
| `vsurv4.c` | async-signal-safe canary：altstack + 固定头 + 8 页栈 | `python tools/zigcc.py cc -target aarch64-linux-musl -static -O2 -o vsurv4 vsurv4.c` | aarch64 编译通过；host plumbing 通过；设备待测 |
| `stackdump.c` | 自然 NE 的 fault-time 栈窗口（16 页） | 同上 | aarch64 编译通过；host 通过；设备待测 |
| `core_meta_v1.7.sh` | `core_meta.sh` + `stackdump` 调用 + `stack=` 列 | `patch -p0 < core_meta_v1.7.patch`（从 `lg6151m-public` 根） | staged；部署前 bump `VERSIONS.tsv` |
| `probe_selftest/` | PF/cfu/uw 正对照模块 + 用户程序 | `tmpfiles/an4/build.sh probe_selftest`；用户态 zig | 模块/用户态已编译；设备待测 |

## 3. Host 自测

```bash
# vsurv4 的 handler plumbing（x86_64 WSL）
MSYS_NO_PATHCONV=1 wsl.exe bash tools/oneoff/sigsegv/test_vsurv4_host.sh

# stackdump 的 [stack] 读取 + 文件格式（x86_64 WSL）
MSYS_NO_PATHCONV=1 wsl.exe bash tools/oneoff/sigsegv/test_stackdump_host.sh
```

## 4. 设备侧顺序（建议）

1. `vsurv4` 自测：`raise(SIGSEGV)`，确认 `h4_<pid>_1.bin` 的 `addr/pc/sp/x2/x8` 与 `siginfo/ucontext` 一致；再跑 `snprintf` 循环。
2. `probe_selftest`：先 `pf`/`cfu`/`uw` 三个正对照；任一失败，对应探针的阴性降级。
3. `stackdump` + `core_meta v1.7`：部署后等一次真实 NE，确认 `.stack` 存在且 header 正确；用 `natural_scan.py --format sd` 解析。
4. 再谈自然 NE 分类（E-01）与三哨兵（E-02）。

## 5. 纪律

- 设备未验证的仪器，其阴性不得写进 `01_CLAIMS.tsv` 的 E2 以上。
- 每次运行记录：日期、boot id、uptime、模块/参数、部署 md5、`dmesg` 原文。
- 旧 `attrib.py`/`h3table.py`/`corescan*.py` 已标 DEPRECATED；不要再用。