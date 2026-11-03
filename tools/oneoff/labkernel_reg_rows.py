#!/usr/bin/env python3
# reg_rows.py -- append labkernel suite rows to tools/VERSIONS.tsv (one-shot,
# run from repo root; tab-exact, UTF-8, notes avoid the vX.Y( bump-check trap)
import hashlib, os, sys
TSV = "tools/VERSIONS.tsv"

def note_pkg(n):
    return n

S = "tools/labkernel/scripts/"
rows = []
def tool(path, desc):
    rows.append((path, "1.0", "tool", "-", desc))

tool(S+"build_labkernel.sh", "labkernel 一键重建入口(WSL 备树内跑 v3 全管线: config 增量->Image/模块->组包->签名->自检电池)")
tool(S+"initramfs_skel.sh", "initramfs 骨架构建(目录+busybox applets+/dev/console 节点+init+helpers; 载荷 md5 钉死见套件 README)")
tool(S+"prep_tree.sh", "从零准备: 解包+535 补丁+files overlay+lg6151m DTS 入树+config 三层合并")
tool(S+"reconfig.sh", "config 组装(观测 26 符号+安全阀+initramfs; olddefconfig 后 26 项核对)")
tool(S+"build_kernel.sh", "C1 基础构建(initramfs 装载+INITRAMFS_SOURCE 接线+Image/dtbs)")
tool(S+"assemble_boot.sh", "C1/C2 组包签名(Android boot v2+MTK mt2737 签名链+cert1 校验)")
tool(S+"export_artifacts.sh", "C1 产物导出(镜像/符号/配置+vmlinux.zst+哈希台账)")
tool(S+"dl_kernel.sh", "内核 tarball 三源竞速下载(sha256 钉死校验)")
tool(S+"make_lg6151m_dts.sh", "lg6151m DTS 生成(仓 dts 骨架+板级身份/chosen 三处替换, python 断言唯一命中)")
tool(S+"get_py310.sh", "uv 装 CPython 3.10.14(MTK 签名工具 .pyc 兼容)")
tool(S+"lab_init.sh", "/init C1 版(自检+心跳+vsurv4)")
tool(S+"lab_init_c2.sh", "/init C2 版(+scanary w1 预注册自启)")
tool(S+"lab_init_v2.sh", "/init v2(F1 console 修复+F2 观测窗后交互 shell+F3 netup)")
tool(S+"lab_init_v3.sh", "/init v3(+A1 热管理心跳带温告警保护关机+A2 看门狗喂狗+A3 TRY_A 自清+A4 boot card; shell/netup 承 v2)")
tool(S+"netup.sh", "/bin/netup: eth* 零配置 169.254.9.n/16 应急传输通道")
tool(S+"romount.sh", "/bin/romount: 分区只读挂载助手(squashfs/ext4 自动尝试, 免网络取证)")
tool(S+"kjump.sh", "/bin/kjump: kexec 助手(内核侧就绪; 用户态 kexec 未内置时如实报缺)")
tool(S+"scanary_report.sh", "/bin/scanary_report: 观测日志 on-device 汇总(busybox awk)")
tool(S+"c2_repack.sh", "C2 台架会话重打包(scanary 补进 initramfs 的先例脚本)")
tool(S+"c2_selfcheck.py", "C1 自检电池 27 项(initramfs 内容/嵌入链/boot 头/签名)")
tool(S+"v2_repack.sh", "v2 重建(F1 cpio 设备节点+F2 init v2+F3 netup; config 零漂移门禁)")
tool(S+"v2_assemble_boot.sh", "v2 组包签名(boot-lab2 产物名)")
tool(S+"v2_selfcheck.py", "v2 电池(C1 29 项继承+F1 解包验证 console 节点+F2 shell 通路静态断言+F3 netup, 共 46 项)")
tool(S+"v2_export.sh", "v2 产物导出+SUMS 再生")
tool(S+"v3_repack.sh", "v3 重建(A 热管理/看门狗/TRYA/boot card + B 模块只构建不加载; 26 观测符号冻结+config 只增不删门禁)")
tool(S+"v3_assemble_boot.sh", "v3 组包签名(boot-lab3 产物名)")
tool(S+"v3_selfcheck.py", "v3 电池(v2 46 项继承+A1/A2/A3/A4 标记+模块 ELF+不自动加载精确断言+26 符号 vs v2 逐项一致)")
tool(S+"v3_export.sh", "v3 产物导出+SUMS 再生(v1+v2+v3 全集)")

tool("tools/labkernel/README.md", "套件文档: 环境记录/上游与载荷 md5 钉死/从零准备/一键构建/自检说明")
tool("tools/labkernel/REPOMETA.txt", "供应链钉死: 基座仓 HEAD/tarball sha256/内核 sha256/stock dtb md5")
tool("tools/labkernel/dts/mt6990-fiberhome-lg6151m.dts", "lg6151m 板级 DTS(仓实机骨架+身份/chosen 替换; 与 stock DTB 逐节点互证)")
tool("tools/labkernel/config/config-lab2-6.18.44", "v2 完整内核 config(与 C1/C2 逐字节一致=零漂移证明件)")
tool("tools/labkernel/config/config-lab3-6.18.44", "v3 完整内核 config(=v2+34 新增: LVTS 热管理+cfg80211/mac80211/mt76 模块栈)")

img_dir = "_drill_backup/labkernel"
for fn in ("boot-lab2-signed.img", "boot-lab3-signed.img"):
    p = os.path.join(img_dir, fn)
    md5 = hashlib.md5(open(p, "rb").read()).hexdigest()
    tag = "v2 实战缺陷修复版(console/shell/netup)" if "lab2" in fn else "v3 资产版(热管理/看门狗/TRYA 自清/boot card/模块储备)"
    rows.append((p.replace("\\", "/"), "1.0", "image", md5, "labkernel 32MiB 签名 boot 镜像; " + tag + "; 构建自检全绿; 见 docs/LABKERNEL.md runbook"))

with open(TSV, "a", encoding="utf-8", newline="\n") as f:
    for name, ver, kind, target, note in rows:
        f.write("\t".join((name, ver, kind, target, note)) + "\n")
print("appended", len(rows), "rows")
