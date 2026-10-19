<div align="center">

# Cirno Reclaim Hybrid · ColorOS 17 适配版

**给 Cirno 墓碑配套的内存回收模块：后台应用尽量不杀，手机尽量不卡**

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![ColorOS 17](https://img.shields.io/badge/ColorOS-17-1BA784)](#coloros-17-说明)
[![KernelSU](https://img.shields.io/badge/KernelSU-supported-4B8BBE)](https://github.com/tiann/KernelSU)

原作者：**flyingr**（[Sui090213/cirno-reclaim](https://github.com/Sui090213/cirno-reclaim)） · ColorOS 17 适配：**yishisanren**

</div>

---

> **状态**：v2.0.0-coloros.1。脚本在 Linux 上模拟 Android 两种 shell 环境（mksh + toybox、busybox）
> 跑过完整的自动化测试（`tests/sim.sh`，真实进程 + 真实 zram），**尚未在真机上验证**。
> 首次安装默认是**演练模式**：只在日志里记录本来会做什么，不压缩、不结束任何进程。
> 回滚：`touch /data/adb/modules/cirno_reclaim/disable` 后重启。

## 这是什么

[Cirno](https://github.com/Freezer-Team/Cirno) 把切到后台 3 秒的应用冻结住：不再占 CPU、不耗电，
但它们占着的内存一直不还。冻结的应用越多，手机可用内存越少，最后系统要么卡（内存回收抢 CPU），
要么自己随机杀后台。

本模块在内存真的紧张时介入，顺序是：

1. **先压缩**：把冻结应用的内存压进 zram（压缩内存）。应用不死，切回来不用重新启动；
2. **还不够才结束**：按占用从大到小，结束冻结中的应用，有单轮 / 每小时上限；
3. **前台应用只在紧张时轻处理**：发 trim 请求 + 少量换出，绝不结束正在用的应用。

内存充足时它什么都不做。

## 相对原版改了什么

### 原版在真机上根本跑不起来（已修）

- `bin/common.sh` 和 `bin/reclaim.sh` 各有一处 case 模式里的 `;`、`(`、`<` 没有转义，
  **mksh、busybox、dash、bash 全部解析失败**。`common.sh` 被所有脚本加载，KernelSU 用 busybox
  跑 `service.sh` 时直接退出，守护进程从来不会启动；mksh 下则后半个函数库都不存在。
  原版的「静态检查」是自写的 Python 脚本，没有用真正的 shell 解析过。
- 现在每个脚本都用 mksh / busybox / dash 实际解析，并在模拟环境里端到端运行。

### 适配 ColorOS 17 + Cirno

| 改动 | 原因 |
|---|---|
| 冻结进程两种 cgroup 布局都认（`apps/uid_*/pid_*` 和 `uid_*/pid_*`） | 与 Cirno 的 `FrozenRW` 判断完全一致；原版只认前一种，另一种布局上永远找不到冻结进程 |
| 按 `cgroup.events` 的实际冻结状态判断 | 冻结写在 uid 层时 pid 层的 `cgroup.freeze` 仍是 0，只看它会漏 |
| 冻结状态下直接结束进程，不先解冻 | cgroup v2 冻结的进程能收到 SIGKILL（系统 lmkd 也这么做）。原版先解冻再等 1 秒，应用会在这一秒里跑起来，也会让 Cirno 记录的状态与实际不一致 |
| 不碰 ColorOS 的「内存扩展」 | ColorOS 的 zram 带写回存储，由系统守护进程管理。ColorOS 上无论配置如何都不重建 zram；`vm_tune` 默认关闭，不改系统内存参数 |
| 保护名单补上 ColorOS 关键组件 | 桌面 `com.android.launcher`、athena、电池、安全中心、HeyTap 推送 / 账号等；默认排除 `com.oplus.*`、`com.coloros.*`、`com.heytap.*` 等系统应用 |
| 诊断信息加入 ColorOS / Cirno 相关项 | cgroup 布局与冻结数、zram / 内存扩展状态、前台识别、root 方案版本 |

### 让手机少卡，而不是多杀

| 改动 | 原因 |
|---|---|
| **先压缩、后结束**（`reclaim_order=pageout_first`，默认） | 配合 Cirno「后台不死」的目标。压缩冻结应用（含 ART 堆，和 Android 对缓存进程做的 full compaction 一致）就够的话，一个都不杀 |
| 大进程看门狗只压缩、不结束 | 原版在内存充足时也会结束单个超过 600MB 的冻结应用 |
| 前台舒缓只在内存紧张时自动执行 | 原版内存充足时也每 90 秒压一次正在用的应用，这正是卡顿来源 |
| 页换出 helper 修正 | 原版把「建议过的地址范围」当成换出量：上限不生效（实测设 64MB 换出 125MB），没有 swap 时也报告换出了上百 MB。现在按常驻匿名页分配预算，按 VmSwap 实际变化报告 |
| helper 由源码重新编译 | zig 0.13 交叉编译，两次编译逐字节一致；不再使用来源不明的预编译文件 |
| WebUI 改用异步执行 | 同步接口执行期间整个页面卡住；老管理器自动退回同步接口 |

---

## 安装

### 环境要求

- ColorOS 17（其他 ColorOS / OxygenOS 版本应可用，未验证）；
- KernelSU / KernelSU Next / SukiSU（Magisk、APatch 也能装，WebUI 需要 KernelSU 系管理器）；
- [Cirno](https://github.com/Freezer-Team/Cirno) 已安装并在 LSPosed 里启用；
- 页换出需要 arm64 + 内核支持 `process_madvise`（5.10+ GKI 都有）。

### 步骤

1. 下载 `dist/Cirno-Reclaim-Hybrid-v2.0.0-coloros.1.zip`，在管理器里刷入，重启；
2. 打开模块 WebUI，概览页会提示「演练模式」；
3. 正常用一两天，看「运行日志」里的 `DRY would pageout` / `DRY would reclaim`：
   这是它本来会压缩 / 结束的应用；
4. 觉得没问题，在「设置」里关掉「演练模式」并保存。

## ColorOS 17 说明

- **内存扩展**：保持系统默认即可。本模块只往已有的 zram 里压缩，不改大小、不重建。
- **省电策略**：把 KernelSU 管理器、Cirno 设为「允许后台运行」。守护进程被系统清掉时 watchdog 会拉起，
  日志里会出现 `WATCHDOG:`。
- **Cirno 白名单**：Cirno 不冻结的应用（系统应用、输入法、它的白名单）本模块也不会动。
- **前台识别**：用 `dumpsys activity` 的 `topResumedActivity`。日志里出现
  `cannot detect foreground package` 时，请把诊断信息提到 Issue。

## 三种预设

WebUI「设置」页顶部，或命令行 `sh /data/adb/modules/cirno_reclaim/bin/ctl.sh preset <名字>`：

| | 保守 | 均衡（默认） | 激进 |
|---|---|---|---|
| 触发阈值 | 600MB / 6% | 800MB / 8% | 1600MB / 12% |
| 目标 | 900MB / 10% | 1200MB / 14% | 2200MB / 18% |
| 单次压缩上限 | 128MB | 256MB | 512MB |
| 结束进程：单轮 / 每小时 | 2 / 8 | 4 / 20 | 6 / 36 |
| 最短冻结 | 15 分钟 | 5 分钟 | 2 分钟 |
| 前台阈值 | 1200MB | 900MB | 700MB |

三档都是「先压缩、不够再结束」。阈值取「绝对值」和「总内存百分比」中较大的那个。

## 工作方式

### 后台回收

触发条件：可用内存低于阈值，或内存压力（PSI `some avg10`）超过 `psi_some_avg10`。

候选必须**同时**满足：应用 UID、`oom_score_adj ≥ 900`（缓存级）、处于冻结状态、不是前台、
不在保护 / 排除名单、PSS ≥ `min_process_mb`、已冻结 ≥ `min_frozen_min` 分钟。

1. 按 PSS 从大到小换出冻结进程的匿名页，直到达到目标或用完 `deep_pageout_max_mb`；
2. 仍低于目标，按 PSS 从大到小结束候选，结束前复核 starttime / oom / 前台 / 冻结状态；
3. 最后才考虑 `drop_caches`（默认关）。

```text
DEEP pid=12345 pkg=com.example.game pss=820MB pageout=256MB
RECLAIM pid=23456 pkg=com.example.video pss=410MB age=900s avail=2050MB est=2310MB mode=pid
```

### 前台舒缓（不结束进程）

只在内存紧张时自动执行（WebUI「舒缓前台」按钮随时可用）：对前台应用的所有进程发
`am send-trim-memory`，再在 `app_pageout_max_mb` 内换出少量匿名页（不含 ART 堆）。

```text
APP RELIEF done pkg=com.ss.android.ugc.aweme pss=1120MB->980MB avail=900MB->1040MB pageout=64MB
```

## 配置

运行时配置：`/data/adb/cirno_reclaim/config.conf`（`0600`）。配置不会被当成脚本执行，
逐行解析、键白名单、按类型校验。改完守护进程下一轮自动重读。

与原版不同或新增的键：

| 键 | 默认 | 说明 |
|---|---:|---|
| `dry_run` | `1` | 首次安装开启演练 |
| `reclaim_order` | `pageout_first` | `kill_first` = 原版顺序 |
| `deep_pageout_max_mb` | `256` | 单次压缩上限 |
| `vm_tune` / `zram_enable` | `0` / `0` | ColorOS 上 zram 无论如何都不动 |
| `exclude_packages` | 见 `config.conf` | 增加了 ColorOS 系统应用前缀 |

其余键与原版相同，完整说明见 `config.conf` 里的注释。

## 命令行

```sh
ctl=/data/adb/modules/cirno_reclaim/bin/ctl.sh

sh $ctl status            # 状态
sh $ctl scan              # 当前候选
sh $ctl run               # 立即回收一次
sh $ctl apprelief --force # 立即舒缓前台
sh $ctl log 120           # 日志
sh $ctl diag              # 诊断信息（提 Issue 用）
sh $ctl preset aggressive
sh $ctl set dry_run=0
sh $ctl restart | start | stop
```

## 反馈

在 WebUI「反馈」页复制诊断信息，到 [Issues](https://github.com/yishisanren/cirno-reclaim/issues) 提交。

## 开发

```sh
# 设备上的 shell 能否解析（比 tools/lint_sh.py 可靠）
for f in *.sh bin/*.sh; do mksh -n "$f" && busybox sh -n "$f"; done

# 端到端模拟（root；需要 mksh busybox toybox original-awk python3 setpriv cc）
sh tests/sim.sh mksh      # /system/bin/sh + toybox + BWK awk
sh tests/sim.sh busybox   # KernelSU 执行模块脚本的环境

# arm64 helper（zig 0.13；没有 zig 时 pip install ziglang==0.13.0 也行）
cd src && ./build.sh

# 打包
python3 tools/pack.py && python3 tools/checksums.py
```

`tests/sim.sh` 会起一批真实进程（真实 UID、内存、`oom_score_adj`），配合假的 cgroup 目录和
`dumpsys` / `am` / `getprop` 桩，在真实 zram 上跑扫描、压缩、结束、前台舒缓、配置写入、
守护全链路与配置注入防护。

## 许可证与致谢

**GPL-3.0-only**，见 [LICENSE](LICENSE)。

- [Cirno](https://github.com/Freezer-Team/Cirno)（Nep-Timeline / Freezer-Team）：冻结器本体；
- **Cirno Reclaim Hybrid**（flyingr）：本项目的上游；
- **HybridRAM**（Razal）：zram / swap 调参思路；
- [KernelSU](https://github.com/tiann/KernelSU)、[Magisk](https://github.com/topjohnwu/Magisk)、[APatch](https://github.com/bmax121/APatch)；
- [Zig](https://ziglang.org/) / musl：arm64 helper 交叉编译。
