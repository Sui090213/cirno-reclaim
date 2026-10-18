<div align="center">

# Cirno Reclaim

**为 Cirno 冻结器设计的内存回收模块**

后台回收已冻结缓存进程 · 前台应用 trim / 页换出 · 不杀前台主进程

[![Android 12+](https://img.shields.io/badge/Android-12%2B-3DDC84?logo=android&logoColor=white)](https://www.android.com/)
[![Magisk](https://img.shields.io/badge/Magisk-supported-00AF9C)](https://github.com/topjohnwu/Magisk)
[![KernelSU](https://img.shields.io/badge/KernelSU-supported-4B8BBE)](https://github.com/tiann/KernelSU)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

[下载](../../releases/latest) · [配置说明](#配置) · [常见问题](#故障排查) · [安全策略](SECURITY.md) · [参与贡献](CONTRIBUTING.md)

</div>

---

> **状态**：v1.3.0。核心逻辑通过 POSIX shell 语法检查、ShellCheck、模拟 `/proc`/cgroup 数据、配置回读和 WebUI 渲染测试；不同 OEM 的内核、cgroup 布局和 SELinux 策略不同，真机行为请以日志为准。
>
> **免责声明**：这是一个需要 root 的系统级模块，会结束后台进程、对前台应用做内存 trim，部分设备上还会把匿名页换出到 zram。请先阅读[安全模型](#安全模型)，并先用 `dry_run=1` 观察。

## 目录

- [这是什么](#这是什么)
- [为什么不是“杀线程”](#为什么不是杀线程)
- [功能](#功能)
- [两条回收路径](#两条回收路径)
- [环境要求](#环境要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [配置](#配置)
- [KsuWebUI](#ksuwebui)
- [命令行](#命令行)
- [安全模型](#安全模型)
- [工作原理](#工作原理)
- [构建](#构建)
- [目录结构](#目录结构)
- [故障排查](#故障排查)
- [卸载与残留](#卸载与残留)
- [安全](#安全)
- [参与贡献](#参与贡献)
- [许可证](#许可证)

## 这是什么

[Cirno](https://github.com/Freezer-Team/Cirno) 通过 cgroup v2 freezer 冻结后台应用。冻结只停止 CPU 调度，**不会释放这些进程占用的物理内存**；当系统内存紧张时，冻结进程仍然占着 PSS。

Cirno Reclaim 是 Cirno 的配套 Magisk / KernelSU / APatch 模块：

- 在内存偏低或单个缓存进程过大时，回收 **Cirno 已冻结**、`oom_score_adj >= 900`、非前台、通过白名单的后台进程；
- 对前台应用使用另一条完全独立的路径：不杀进程、不杀线程，只让应用释放缓存，并可选地把部分匿名页换出到 zram；
- 配置持久化，支持命令行和 KsuWebUI；
- 日志放在模块目录内，卸载时随模块一起删除。

本项目与 Freezer-Team / Cirno 官方没有隶属关系，只通过标准 `/proc`、cgroup v2 和 Android ActivityManager 接口协作。

## 为什么不是“杀线程”

一个 Android 应用的所有线程共享同一套地址空间、堆、锁、Binder 状态和 ART 运行时。**单独杀掉“占用高的线程”无法保证应用还能继续运行**，常见结果是崩溃、ANR、画面卡死或数据损坏。

因此本模块不做线程级 kill，而是采用两条可恢复的路径：

| 路径 | 对象 | 动作 | 是否结束进程 |
|---|---|---|---|
| 后台回收 | 已冻结缓存进程 | 解冻后 `SIGKILL` | 是 |
| 前台舒缓 | 当前前台应用 | `am send-trim-memory` + 可选 `MADV_PAGEOUT` | **否** |

前台舒缓会把页面换出到 zram/swap，线程、锁、Binder 和 Java 堆都保留；应用再次访问这些页时由内核换回。代价是可能有一次缺页，所以有单次上限和冷却时间。

## 功能

- 与 Cirno 的 per-pid freezer 配合，不修改 Cirno 本体。
- 依据 `MemAvailable` 触发，可设置低内存阈值和目标可用内存。
- 单进程高内存看门狗：任意已冻结缓存进程 PSS 达到阈值就主动回收，即使总可用内存还充足。
- 前台应用总 PSS 监控：汇总同一包名所有进程的 PSS 和线程数，超过阈值时舒缓。
- 只回收缓存级后台进程；保护前台、系统界面、输入法、桌面、电话、蓝牙、闹钟、GMS、Cirno、Magisk/KernelSU 管理器等。
- 冻结时长追踪：刚切到后台的应用不会立刻被杀。
- 四层限额：冻结冷却、单次上限、每小时上限、回收冷却。
- 两种后台回收方式：精确 PID 或 `am kill`。
- 可选 `drop_caches`（默认关闭）。
- KsuWebUI：状态、配置、候选扫描、立即回收、前台舒缓、日志。
- KernelSU 动作按钮：执行一次手动回收并显示日志。
- 日志/轮转日志位于模块目录，卸载时完整清理。

## 两条回收路径

### 1. 后台进程回收

每一轮自动检查：

1. `MemAvailable < mem_low_mb`，或 `high_pss_mb` 看门狗发现超大冻结进程；
2. 扫描 `/proc/<pid>/`，只保留：
   - 应用 UID（`uid % 100000` 在 `10000..19999`）；
   - `oom_score_adj >= min_oom_score_adj`（默认 900）；
   - `cgroup.freeze=1`（默认要求）；
   - 非前台应用；
   - 不在 `exclude_packages`，或命中 `include_packages`；
   - PSS ≥ `min_process_mb`；
   - 冻结时间 ≥ `min_frozen_min`；
3. 按 PSS 从大到小，先解冻、再结束，测 `MemAvailable`；
4. 达到 `mem_target_mb`、单次上限或每小时上限就停止。

默认值非常保守，不会因为“内存看起来高”就动前台应用。

### 2. 前台应用内存舒缓

`app_relief.sh` 独立运行，永不结束前台主进程：

1. 取当前前台包名；
2. 汇总该包所有进程的 PSS 和 `Threads`；
3. 超过 `app_pss_mb` 时，向主进程发送 `am send-trim-memory`；
4. 如果 `app_pageout=1` 且 arm64 helper 可用，再用 `process_madvise(MADV_PAGEOUT)` 把最多 `app_pageout_max_mb` 的私有匿名页换出；
5. 跳过 stack、code、GPU、Dalvik、JIT、`/dev/`、`/system/`、`/apex/` 等映射；
6. 冷却后才会再次执行。

示例（抖音）：

```ini
app_reclaim=1
app_pss_mb=1000
app_reclaim_interval=60
app_reclaim_cooldown=120
app_trim_level=RUNNING_LOW
app_pageout=1
app_pageout_max_mb=128
```

如果换出后反而卡顿，把 `app_pageout=0`，只保留更温和的 trim。

## 环境要求

- Android 12+；
- cgroup v2（Cirno 本身要求内核 5.0+）；
- Magisk、KernelSU 或 APatch；
- 已安装并启用 Cirno 本体和它要求的模块；
- 前台页换出额外需要：
  - arm64 设备；
  - 内核支持 `pidfd_open` + `process_madvise`（常见于 5.10+ GKI）；
  - 有 zram/swap 时效果最好。

不满足页换出条件时会自动回退到 `am send-trim-memory`，不会导致模块启动失败。

## 安装

1. 先装好 Cirno 本体、LSPosed 和 Cirno 要求的必备模块，确认 Cirno 能正常冻结后台应用。
2. 从 [Releases](../../releases/latest) 下载最新的 `Cirno-Reclaim-v1.3.0.zip`。
3. 在 Magisk / KernelSU / APatch 中刷入。
4. 重启手机。
5. 打开模块 WebUI，确认底部版本为 **v1.3.0**，守护状态为“守护运行中”。

升级安装不会覆盖已有 `/data/adb/cirno_reclaim/config.conf`；新增配置项会使用默认值。

> 如果更新后 WebUI 仍显示旧版本，强制停止 KernelSU / KsuWebUI 后重新打开，或重启一次。

## 快速开始

默认配置已经比较保守。第一次使用建议：

```sh
# 1. 先演练，只记录不杀
sed -i 's/^dry_run=.*/dry_run=1/' /data/adb/cirno_reclaim/config.conf
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh restart

# 2. 观察日志
tail -f /data/adb/modules/cirno_reclaim/log/reclaim.log

# 3. 确认没有误伤后关闭演练
sed -i 's/^dry_run=.*/dry_run=0/' /data/adb/cirno_reclaim/config.conf
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh restart
```

日志里会看到：

```text
RECLAIM pid=... pkg=... pss=...MB age=...s mode=pid
APP RELIEF start pkg=... pid=... pss=...MB threads=... level=RUNNING_LOW pageout=1
```

## 配置

配置文件：

```text
/data/adb/cirno_reclaim/config.conf
```

修改后守护进程会在下一个周期重新读取，也可以：

```sh
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh restart
```

> `exclude_packages` / `include_packages` 含分号，手动编辑时请用单引号包住，例如：
> `exclude_packages='com.tencent.mm;com.tencent.mobileqq'`

### 通用

| 键 | 默认 | 说明 |
|---|---:|---|
| `enable` | `1` | 总开关 |
| `dry_run` | `0` | 只记录不杀，调试用 |
| `interval` | `30` | 守护检查周期（秒） |
| `boot_delay` | `120` | 开机后额外等待（秒） |
| `log_max_kb` | `256` | 日志上限，超过后轮转 |

### 后台进程回收

| 键 | 默认 | 说明 |
|---|---:|---|
| `mem_low_mb` | `800` | 可用内存低于此值触发；`0` = 始终检查 |
| `mem_target_mb` | `1200` | 达到此可用内存后停止本轮 |
| `high_pss_mb` | `800` | 单个已冻结缓存进程 PSS 达到此值就触发；`0` = 关闭 |
| `high_pss_interval` | `120` | 高内存看门狗检查周期（秒） |
| `max_kills_per_run` | `3` | 单次最多回收进程数；`0` = 不限制 |
| `max_kills_per_hour` | `12` | 最近 1 小时最多回收进程数；`0` = 不限制 |
| `cooldown_sec` | `180` | 两次自动回收的最小间隔 |
| `min_process_mb` | `64` | 小于此 PSS 的进程不回收 |
| `min_frozen_min` | `10` | 至少冻结多少分钟才允许回收 |
| `min_oom_score_adj` | `900` | 只处理缓存级进程，**不要随意调低** |
| `only_frozen` | `1` | 只回收 `cgroup.freeze=1` 的进程 |
| `kill_mode` | `pid` | `pid` = 精确结束单进程；`am` = 结束该包后台进程 |
| `protect_foreground` | `1` | 额外保护当前前台应用 |
| `screen_off_only` | `0` | 只在息屏时自动回收 |
| `drop_caches` | `0` | 回收后顺便清页缓存 |
| `drop_caches_cooldown` | `1800` | 清页缓存冷却（秒） |
| `allow_system_uid` | `0` | 允许处理系统 UID；**强烈建议保持 0** |

### 前台应用舒缓

| 键 | 默认 | 说明 |
|---|---:|---|
| `app_reclaim` | `1` | 启用前台应用内存舒缓 |
| `app_pss_mb` | `1200` | 前台应用所有进程 PSS 总和阈值；`0` = 关闭 |
| `app_reclaim_interval` | `60` | 前台应用检查周期（秒） |
| `app_reclaim_cooldown` | `120` | 两次舒缓的冷却（秒） |
| `app_trim_level` | `RUNNING_LOW` | `RUNNING_MODERATE` / `RUNNING_LOW` / `RUNNING_CRITICAL` |
| `app_pageout` | `1` | 用 `process_madvise(MADV_PAGEOUT)` 换出匿名页（需内核支持） |
| `app_pageout_max_mb` | `128` | 单次页换出上限 |
| `app_proc_reclaim` | `0` | 尝试 OEM `/proc/<pid>/reclaim`，默认关闭 |

### 包名过滤

| 键 | 默认 | 说明 |
|---|---:|---|
| `include_packages` | 空 | 只回收这些包；空 = 全部 |
| `exclude_packages` | 见文件 | 永不回收的包；支持 `*` 通配符 |

系统界面、输入法、桌面、电话、蓝牙、NFC、闹钟、Cirno、Magisk/KernelSU 管理器等关键包有硬编码保护，即使从名单删除也不会被后台回收。

### 推荐调法

- **8GB 及以下**：`mem_low_mb=700`、`mem_target_mb=1100`、`max_kills_per_run=3`。
- **12GB 及以上**：`mem_low_mb=1000`、`mem_target_mb=1600`。
- 想更积极：`min_frozen_min=5`、`max_kills_per_run=4`。
- 想更保守：`min_frozen_min=20`、`max_kills_per_run=2`、`screen_off_only=1`。
- 抖音等前台应用：`app_pss_mb=900~1000`、`app_pageout_max_mb=96~128`。
- 页换出导致卡顿：`app_pageout=0`。

## KsuWebUI

支持：

- **KernelSU 官方管理器**：模块详情 → 打开 WebUI；
- **KsuWebUIStandalone**：模块列表选择“Cirno 内存回收”。

页面功能：

- 可用内存 / 总内存 / Swap；
- 累计释放、累计回收、上次回收结果；
- 修改全部常用配置并保存；
- 扫描当前后台候选；
- 立即回收后台进程；
- “舒缓前台”：对当前前台应用执行 trim / 页换出；
- 重启守护、查看日志。

保存时 `ctl.sh save` 会验证文件确实写入并完成重命名；配置值被正常归一化时不会弹“回读错误”。

## 命令行

```sh
ctl=/data/adb/modules/cirno_reclaim/bin/ctl.sh

sh $ctl status          # JSON 状态
sh $ctl scan            # 文本候选列表
sh $ctl run             # 立即回收一次（JSON）
sh $ctl apprelief       # 立即舒缓前台应用
sh $ctl log             # 最近日志
sh $ctl restart         # 重启守护
sh $ctl stop            # 停止守护
sh $ctl start           # 启动守护
```

直接运行：

```sh
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --scan
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --manual
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --manual --dry-run
sh /data/adb/modules/cirno_reclaim/bin/app_relief.sh --force
```

## 安全模型

本模块拥有 root 权限，安全边界必须明确：

1. **后台 kill 只对缓存级后台进程**：应用 UID、`oom_score_adj>=900`、默认 `cgroup.freeze=1`、非前台、通过名单。
2. **前台不 kill**：`app_relief.sh` 只发送 trim / 页换出；不结束主进程，不杀线程。
3. **硬编码保护**：`android`、`com.android.systemui`、`com.android.shell`、`nep.timeline.cirno`。
4. **默认保护**桌面、输入法、电话、蓝牙、NFC、闹钟、设置、GMS、Magisk/KernelSU 管理器等。
5. **限额与冷却**：单次、每小时、冻结时间、回收冷却、前台舒缓冷却。
6. **竞态检查**：解冻后、kill 前再次检查 oom 和包名。
7. **失败安全**：解冻失败放弃该进程；页换出失败回退 trim，不影响启动。
8. **权限**：配置 `0600`、数据目录 `0700`、日志 `0600`（`umask 077`）。
9. **无网络**：模块不联网、不上传数据、不包含遥测。
10. **完整卸载**：删除数据目录、模块内日志、轮转日志和 `nohup.out`。

> 配置文件由 root 脚本 `source`。它位于 `0700` 目录、权限 `0600`，只应由 root 修改。不要把配置放到其他应用可写的位置。

更完整的报告流程、发布检查清单和已知限制见 [SECURITY.md](SECURITY.md)。

## 工作原理

### 后台路径

1. 读 `/proc/meminfo` 的 `MemAvailable`，或由 `high_pss_mb` 触发；
2. 扫描 `/proc/<pid>/`，读取 UID、`oom_score_adj`、cgroup freeze、cmdline、`smaps_rollup`；
3. 用 `state/frozen.tsv` 记录 `pid + starttime` 首次被看到冻结的时间；
4. 排序、过滤、解冻、结束、测量；
5. 记录 `reclaim.log` 和统计文件。

### 前台路径

1. `dumpsys activity activities` 获取前台包名；
2. 汇总同包所有进程的 PSS 和 `Threads`；
3. `am send-trim-memory`；
4. 可选 `process_madvise(MADV_PAGEOUT)`，由 `src/cirno_pageout.c` 编译的 arm64 helper 执行；
5. 只处理私有匿名映射，跳过 stack/code/GPU/Dalvik/JIT；
6. 不结束进程，不杀线程。

### 状态文件

```text
/data/adb/cirno_reclaim/
├── config.conf
├── daemon.pid
└── state/
    ├── frozen.tsv
    ├── last_run
    ├── last_app_check
    ├── last_app_run
    └── ...
```

日志在模块目录：

```text
/data/adb/modules/cirno_reclaim/log/reclaim.log
```

## 构建

### 依赖

- Android 设备上的 `/system/bin/sh`、toybox；
- 开发机：`shellcheck`、Node.js（检查 JS 语法）、Python 3（打包可选）；
- 仅重新编译原生 helper：Zig 0.13+。

### 检查

```sh
find . -name '*.sh' -exec sh -n {} \;
shellcheck -s sh bin/*.sh *.sh
node --check webroot/app.js
```

### 编译 arm64 helper

```sh
cd src
zig cc -target aarch64-linux-musl -static -Os -s \
    -o ../bin/cirno_pageout cirno_pageout.c
```

### 打包

模块 zip 的根目录必须直接包含 `module.prop`：

```sh
# 推荐：只打包已跟踪文件
git archive --format=zip -o ../Cirno-Reclaim-v1.3.0.zip HEAD

# 或者在没有 git 时手动打包
cd Cirno-Reclaim
zip -r ../Cirno-Reclaim-v1.3.0.zip . \
    -x 'log/*' '*.log' 'state/*' 'tmp-test/*'
```

不要把 `log/`、`state/`、本地配置或测试数据打进发布包。

## 目录结构

```text
Cirno-Reclaim/
├── module.prop
├── customize.sh
├── post-fs-data.sh
├── service.sh
├── uninstall.sh
├── action.sh
├── config.conf
├── LICENSE
├── README.md
├── CONTRIBUTING.md
├── SECURITY.md
├── .gitignore
├── bin/
│   ├── common.sh
│   ├── daemon.sh
│   ├── reclaim.sh
│   ├── app_relief.sh
│   ├── ctl.sh
│   └── cirno_pageout        # arm64，可选
├── src/
│   ├── cirno_pageout.c
│   └── build.sh
└── webroot/
    ├── index.html
    ├── style.css
    └── app.js
```

## 故障排查

### 扫描结果一直是空的

```sh
# Cirno 是否在冻结
cat /sys/fs/cgroup/apps/uid_<uid>/pid_<pid>/cgroup.freeze

# 候选
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --scan

# 日志
tail -n 120 /data/adb/modules/cirno_reclaim/log/reclaim.log
```

常见原因：

- Cirno 没有正常工作，进程没有被冻结；
- `oom_score_adj` 低于 900（例如仍在播放音乐、导航、录音）；
- 冻结时间未到 `min_frozen_min`；
- PSS 小于 `min_process_mb`；
- 包名在 `exclude_packages`；
- 设备不是 per-pid cgroup freeze 布局，模块安全跳过。

### 前台舒缓没有明显效果

- 应用可能不响应 trim-memory；
- 内核不支持 `process_madvise`，日志会出现 `pageout rc=2` 或 `rc=3`；
- 没有 zram/swap，匿名页无法换出；
- 把 `app_pss_mb` 调低，或检查 `APP RELIEF` 日志中的 PSS 前后变化；
- 页换出后更卡：设 `app_pageout=0`。

### 保存提示“回读不一致”

v1.3.0 已不再因为数值归一化弹错误。如果仍看到 `ctl.sh` 返回的写入错误：

```sh
su -c 'touch /data/adb/cirno_reclaim/.w && echo WRITABLE && rm /data/adb/cirno_reclaim/.w'
su -c 'ls -lZ /data/adb/cirno_reclaim/config.conf'
```

### 日志没有生成

检查模块目录是否可写：

```sh
su -c 'ls -ld /data/adb/modules/cirno_reclaim /data/adb/modules/cirno_reclaim/log'
```

### 升级后 WebUI 还是旧版本

强制停止 KernelSU / KsuWebUI 后重新打开；仍不行则重启。

## 卸载与残留

在 Magisk / KernelSU / APatch 中卸载模块。`uninstall.sh` 会：

- 停止守护进程；
- 删除 `/data/adb/cirno_reclaim`（配置、状态、pid、lock、旧版日志）；
- 删除模块内 `log/`、轮转日志和 `nohup.out`；
- 模块目录由管理器移除。

手动删除时：

```sh
rm -rf /data/adb/modules/cirno_reclaim
rm -rf /data/adb/cirno_reclaim
```

不要在未停止守护进程时只删除数据目录；先卸载模块或执行 `ctl.sh stop`。

## 安全

- 安全策略、威胁模型和发布检查清单：[SECURITY.md](SECURITY.md)
- 发现漏洞请通过 GitHub Security Advisory 私下报告，不要公开提交可复现的 root 利用细节。
- 本项目不联网、不收集遥测、不包含分析 SDK。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。欢迎：

- 真机兼容性报告（品牌、Android 版本、内核、cgroup 布局）；
- 误杀/漏杀日志；
- WebUI 和文档改进；
- 原生 helper 的兼容性修复。

## 许可证

本项目使用 **GNU General Public License v3.0 only**（GPL-3.0-only）。完整文本见 [LICENSE](LICENSE)。

选择 GPL-3.0 的原因：

- Cirno 本身使用 GPL-3.0，配套模块采用同一协议最符合社区预期；
- 这是一个拥有 root 权限的系统级模块，copyleft 能确保分发者继续公开修改；
- 预编译的 arm64 helper 同时提供 `src/cirno_pageout.c` 和构建脚本，满足 GPL 的源码要求。

如果你分发修改后的模块或二进制，请保留版权声明、许可证和源码获取方式。

## 致谢

- [Cirno](https://github.com/Freezer-Team/Cirno)：冻结器与 cgroup v2 思路；
- [KernelSU](https://github.com/tiann/KernelSU)、[Magisk](https://github.com/topjohnwu/Magisk)、[APatch](https://github.com/bmax121/APatch)：模块运行环境；
- [Zig](https://ziglang.org/) / musl：arm64 helper 交叉编译；
- 所有提交日志、测试报告和 issue 的贡献者。

---

<div align="center">

**Cirno Reclaim** · 让冻结进程真正把内存还给系统，同时不把前台应用清掉。

</div>
