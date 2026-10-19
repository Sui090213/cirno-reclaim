# Changelog

本项目从 v2.0.0 开始整合 **cirno-reclaim**（由 Cirno 派生）与 **HybridRAM**。

## v2.0.0-coloros.1 — ColorOS 17 适配

适配：yishisanren（基于 flyingr 的 v2.0.0）

### 修复（原版在真机上无法运行）

- `bin/common.sh` 的 `include_packages|exclude_packages` 校验与 `bin/reclaim.sh` 的
  `REASON` 校验里，case 模式中的 `;`、空格、`(`、`)`、`<`、`>` 未转义，
  mksh / busybox / dash / bash 全部解析失败。`common.sh` 被所有脚本加载，
  busybox（KernelSU 执行 `service.sh` 的环境）下直接退出，守护进程从不启动。
- `cirno_pageout`：把 `process_madvise` 的返回值（建议过的地址长度）当成换出量。
  `--max-mb` 不生效（设 64MB 实测换出 125MB），没有 swap 时也报告换出上百 MB。
  现在按常驻匿名页分配预算、按 VmSwap 实际变化报告。

### ColorOS 17 / Cirno 适配

- 冻结进程同时支持 `apps/uid_*/pid_*` 与 `uid_*/pid_*` 两种 cgroup 布局（与 Cirno `FrozenRW` 一致），
  按 `cgroup.events` 的实际冻结状态判断（含 uid 层冻结）。
- 冻结状态下直接 SIGKILL，不再先解冻等 1 秒；极少数收不到信号时才解冻重试。
- ColorOS 上永不重建 zram；`vm_tune`、`zram_enable` 默认 0。
- 硬保护名单加入 ColorOS 桌面、athena、电池、安全中心、HeyTap 推送 / 账号、KernelSU Next、LSPosed、Shizuku 等；
  默认 `exclude_packages` 加入 `com.oplus.*`、`com.coloros.*`、`com.heytap.*`、`com.oppo.*`、`com.nearme.*`、`com.finshell.*`。
- 诊断信息加入 ColorOS 版本、cgroup 布局与冻结数、zram / 内存扩展状态、前台识别、root 方案版本。

### 行为变更

- 新增 `reclaim_order`（默认 `pageout_first`）：先把冻结应用压进 zram（含 ART 堆），不够才结束进程。
- 大进程看门狗在 `pageout_first` 下只压缩、不结束。
- 前台舒缓只在内存紧张（低于阈值或 PSI 超标）时自动执行。
- `deep_pageout_max_mb` 默认 96 → 256；首次安装 `dry_run=1`。
- 手动回收时若还没有桌面 / 输入法保护名单，先现取一次。
- WebUI：异步 `ksu.exec`（老管理器自动退回同步），演练模式提示，压缩量统计，反馈改为 GitHub Issue。

### 工程

- `tests/sim.sh`：在 Linux 上模拟 mksh + toybox 与 busybox 两种环境，真实进程 + 真实 zram 端到端测试。
- `bin/cirno_pageout` 由 `src/cirno_pageout.c` 用 zig 0.13 重新编译（可复现）；`src/build.sh` 支持 pip 安装的 zig。

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
