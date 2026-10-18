# Changelog

本项目从 v2.0.0 开始整合 **cirno-reclaim**（由 Cirno 派生）与 **HybridRAM**。

## v2.0.0 — 整合版

作者：flyingr

### 新增

- **三层保活**：`service.sh` → `watchdog.sh` → `daemon.sh`，用 pid + 命令行 + 心跳三重判断，
  掉线自动拉起，带 20s / 300s 节流，避免重启风暴。
- **深回收**：杀完仍低于目标时，把冻结进程的私有匿名页换出（`deep_reclaim` / `deep_pageout_max_mb`）。
- **PSI 触发**：读 `/proc/pressure/memory` 的 `some avg10`，不再只看 `MemAvailable`。
- **百分比阈值**：`mem_low_pct` / `mem_target_pct`，按总内存自适应。
- **多轮回收**：`max_rounds` 分批重扫，而不是扫一次就结束。
- **前台全 PID trim**：`app_trim_all_pids`，对该包所有进程发 `send-trim-memory`。
- **前台多轮换出**：`app_pageout_passes`，每轮重新读 smaps 并按 PSS 分配预算。
- **前台效果可验证**：日志与 WebUI 输出 `PSS before → after` 和可用内存增量。
- **预设**：`conservative` / `balanced` / `aggressive`，WebUI 一键切换。
- **全新 WebUI**：概览 / 设置 / 反馈三页，无框架、无 CDN、不联网。
- **问题反馈页**：内置邮箱 `asui20090213@outlook.com`，支持一键复制诊断信息与写邮件。
- **KernelSU 支持**：`customize.sh` 识别 KSU / Magisk / APatch，带 `action.sh` 与 `webroot/`。
- **zram / swapfile / VM 调参**：吸收 HybridRAM 思路，代码重写；`vm_reassert` 定时回写被 Android 重置的参数。
- **原生 helper**：`src/cirno_pageout.c` + zig 交叉编译脚本，CI 自动构建。
- **工程规范文件**：`.editorconfig`、`.gitattributes`（强制 LF）、`CODE_OF_CONDUCT.md`、
  Issue 表单（bug_report.yml / config.yml）、PR 模板、`docs/SECURITY-AUDIT.md`、
  `tools/checksums.py`（生成 / 校验 SHA-256）。

### 安全

- **配置文件不再被 `source`**：改为逐行解析 + 键白名单 + 按类型校验 + `case` 直接赋值，
  `;`/空格/`$(...)`/`#` 都不再可能变成命令；键白名单挡住 `PATH=`、`LD_PRELOAD=` 这类注入。
- `ctl.sh save` / `set` 复用同一套类型校验，所有值单引号写入，`zram_algorithm` 改为精确枚举。
- `interval` / `watchdog_interval` / `heartbeat_timeout` 增加下限与联动（`cfg_clamp`），
  避免 `interval=0` 忙循环或心跳不匹配导致周期性重启。
- pid 文件与锁全部加入命令行核对；单实例锁改为 `mkdir` 原子锁（daemon / watchdog / reclaim 各一把）。
- `kill` 在解冻后重新校验 starttime / oom / 前台 / 保护名单，不满足就把进程冻回去。
- zram 重建增加 `/proc/swaps` basename 匹配、`swapoff` 失败即中止、`reset` 与忙检测；
  swapfile 增加剩余空间检查与「活动文件不删除」保护。
- WebUI 配置读取失败时禁用保存，缺失的布尔键不再被写成 0；轮询 5s→15s。
- 新增 `SECURITY.md` 第 7 节「发布检查清单」与 `docs/SECURITY-AUDIT.md`（含两轮审计记录）。

### 变更

- 默认值更积极：`max_kills_per_run` 3→4、`max_kills_per_hour` 12→20、`min_frozen_min` 10→5、
  `min_process_mb` 64→48、`interval` 30→15、`app_pageout_max_mb` 128→192。
- 配置读取增加语法检查，配置文件损坏时保留上一份内存中的值而不是让守护崩溃。
- 日志统一到模块目录 `log/reclaim.log`，按 `log_max_kb` 轮转。
- `ctl.sh` 保存配置改为「白名单 + 类型校验 + 临时文件原子替换」。
- 模块 id 保持 `cirno_reclaim`，可从 cirno-reclaim 直接升级。

### 修复

- 修复上游前台只 trim 主进程、效果有限的问题。
- 修复回收循环在第一次达到目标后过早退出、单次回收数量过少的问题。
- 修复守护进程被杀后无人拉起、WebUI 显示「掉线」的问题。
- 修复升级安装时旧守护进程仍在跑、与新版本抢配置的问题。

### 已知限制

- **未在真机验证**：只做了静态检查与打包校验，`dumpsys` 解析、`am send-trim-memory`、
  cgroup 路径等仍需在 AOSP / HyperOS / ColorOS 等设备上确认；
- 需要 Cirno 本体才能真正「冻结」，本模块只负责回收；
- 前台页换出需要 arm64 + 内核 `pidfd_open` + `process_madvise`，否则自动降级为 trim；
- 已内置 arm64 `bin/cirno_pageout`（zig 0.18.0-dev 静态编译，约 56KB，无动态链接、无解释器），
  源码仍在 `src/`；非 arm64 设备安装时自动移除；
- 工作资料 / 多用户的 cgroup 目录可能是 `uid_<appid>`，未做双路径兜底；
- 卸载后 `swappiness` 等 sysctl 需要重启才恢复默认（Android 开机时会重置）。
