# 2026-10-31-02 .stack/.stackerr 验证（D 轨道）

## 0. 预登记
- 假设：core_meta v1.9 的 .stack/.stackerr 在真实死亡的进程上可用；vsurv4 捕获 SIGSEGV，不会进 core_meta。
- 判据：.stack 存在且 .stackerr 报告 readable=16；ne_events 有 stack= 路径。
- 正控：一个 STOPped 进程 + 手工调用 core_meta.sh。

## 1. 实验
- 部署 /data/repro/stacktest.sh：
  ```
  sleep 300 & p=$!; kill -STOP $p; /data/gw/core_meta.sh $p 11 0 0
  ```
- 运行后：脚本自身 sh 以 SIGSEGV 死亡（ne_events 1788938961, pid 15214, sh /data/repro/stacktest.sh），进入 core_meta。

## 2. 结果
- .stack：/data/gw/logs/cores/meta/1788931165-15214-1788938961.stack，**65,592 B**。
- .stackerr：`stackdump: pid=15214 pages=16 readable=16 start=0x7fc8654000 end=0x7fc8664000` —— **成功**。
- ne_events 行含 `stack=/data/gw/logs/cores/meta/1788931165-15214-1788938961.stack`。
- 结论：**core_meta v1.9 + stackdump 在真实死亡进程上工作正常**（C-141）；此前 .stack 缺失是 v1.7 之前/触发上下文问题，不是 stackdump 本身。
- 注意：vsurv4 捕获 SIGSEGV 后 siglongjmp，**不会**进入 core_meta；.stack 只能在真正死亡的进程上验证。

## 3. 自然 .stack 的记录扫描
- 对 16 页做 shape 扫描：3 个 shape 命中（60032 B0A2、60344 B0A2、61016 A0B2）。
- 用 len|ip 判据复核：w2 高 32 位为 0 或为栈指针（0x4a0820/0x7fc8662d60），**不满足** len∈[0x100,0x10000] 且高 32 为 IP -> **都是形状巧合，不是记录**。
- 自然 NE 份额更新：**0/4**（3 自然 core + 1 自然 .stack），Wilson 95% 上界 **49.0%**（C-142）。

## 4. 清理
- 杀掉 3 组卡住的 core_meta.sh/stackdump（旧 pid 6367/25435/32140）和 STOPped 的 sh。
