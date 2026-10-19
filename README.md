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
> **状态**：v2.2.2。已通过 POSIX shell 静态检查、`node --check`、配置解析与打包结构校验，
> **尚未在真机上完整验证**。首次刷入建议先设 `dry_run=1`、`zram_enable=0` 观察一轮，
> 并先想好回滚方式（`touch /data/adb/modules/cirno_reclaim/disable` 后重启）。
>
> 审计与已知风险见 [SECURITY.md](SECURITY.md) 与 [docs/SECURITY-AUDIT.md](docs/SECURITY-AUDIT.md)。

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
| 全 PID trim | `app_trim_all_pids=1`：对该包**所有**进程发 `am send-trim-memory`，不只是主进程 |
| 多轮换出 | `app_pageout_passes=3`：每轮重新读 smaps、按当前 PSS 分配预算，越换越干净 |
| 更大预算 | 单次上限 192MB（上游 128MB） |
| 结果可验证 | 日志与 WebUI 都给出 `PSS before → after` 和可用内存增量，效果不好一眼能看出来 |
| 失败自动降级 | helper 不可用 / 内核不支持时退化为纯 trim，不影响模块启动 |

### 3. 模块偶尔「掉线」

上游只有一个守护进程，被 LMK 杀掉或被系统清理后就没有任何东西会把它拉起来。

现在改成三层保活，并且最里面那层换成了 **C++ 守护**：

```
service.sh（外层循环，30s 巡检）
   └── watchdog.sh（心跳看护，30s 一次）
          └── cirno_daemon（C++ 静态二进制，默认引擎）
                 └── sh reclaim.sh / app_relief.sh（具体回收逻辑）
```

- `cirno_daemon` 用单调时钟调度，每 5 秒写心跳；子进程有硬超时，
  `dumpsys` 卡住时直接 SIGKILL，不会把守护一起拖死；
- `watchdog.sh` 检查 pid + 命令行 + 心跳年龄，超时就重启 daemon；
- `service.sh` 检查前两者，掉了就补；
- `watchdog` 也会反向检查 `service.sh`，它死了会 `service.sh --resume` 重新拉起；
- 三者 `oom_score_adj` 都设为 `-900`，尽量不被 LMK 选中；
- 所有重启都有 20s / 300s 的节流；`interval` / `heartbeat_timeout` 还会被 `cfg_clamp`
  夹到安全区间（`interval ≥ 5s`、`heartbeat_timeout ≥ 3×interval`），正常配置不会出现重启风暴。
- 配置 `daemon_engine=shell` 可以回退到原来的纯 shell 守护（没有 C++ 二进制的设备会自动回退）。

WebUI 顶部的圆点就是守护状态，`控制台` 的圆环与心跳能看到 daemon 多久没动了。

### 4. WebUI 太复杂

重做成四页、无框架、无外部请求，布局参考 HyperOS 控制台：

- **控制台**：圆环仪表（可用内存百分比）+ 两个数据块 + 四个动作按钮 + 设备信息 + 日志 + 自检；
- **场景**：三个预设（保守 / 均衡 / 激进）+ 常用设置 + 高级参数折叠；
- **外观**：跟随系统 / 浅色 / 深色、四种强调色、纯色或图片背景（链接或本地图片）、组件透明度；
- **关于**：版本、反馈邮箱、一键复制诊断、写邮件、仓库地址。

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

### VM / 交换

| 键 | 默认 | 说明 |
|---|---:|---|
| `vm_tune` | `1` | 总开关 |
| `zram_enable` / `zram_disksize_mb` | `1` / `0` | 0 = 总内存一半，上限 6GB |
| `zram_algorithm` | `lz4` | 不支持时自动回退 |
| `swapfile_enable` / `swapfile_mb` | `0` / `2048` | 存储交换文件，默认关 |
| `swappiness` | `80` | zram 为主时 80~150 都合理 |
| `vfs_cache_pressure` | `100` | |
| `dirty_writeback_centisecs` | `1500` | |
| `dirty_expire_centisecs` | `500` | |
| `page_cluster` | `1` | |
| `io_tune` / `read_ahead_kb` | `0` / `128` | 与内存无关，默认关 |

### 保活

| 键 | 默认 | 说明 |
|---|---:|---|
| `keepalive` | `1` | 启用看门狗 |
| `watchdog_interval` | `30` | 检查周期 |
| `heartbeat_timeout` | `180` | 心跳多久没更新算掉线 |
| `oom_protect` | `1` | 守护进程 `oom_score_adj=-900` |
| `daemon_engine` | `cpp` | `cpp` = C++ 守护（推荐）；`shell` = 纯脚本守护 |

### 名单

| 键 | 说明 |
|---|---|
| `include_packages` | 只回收这些包；空 = 全部 |
| `exclude_packages` | 永不回收，分号分隔，支持 `*`，**手动编辑要用单引号包住** |

系统界面、输入法、桌面、电话、蓝牙、NFC、设置、GMS、Magisk/KernelSU 管理器、Cirno 本体都是硬保护，从名单里删掉也不会被回收。

---

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

直接跑引擎也可以：

```sh
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --scan
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --run --dry-run
sh /data/adb/modules/cirno_reclaim/bin/app_relief.sh --force --json
```

---

## WebUI

KernelSU / KsuWebUIStandalone 打开模块即可，页面在 `webroot/`，纯静态、不联网。

| 页 | 内容 |
|---|---|
| 控制台 | 圆环仪表（可用 %）、可用/Swap、累计回收与释放、守护引擎、页换出状态、立即回收、舒缓前台、扫描、重启、日志、自检 |
| 场景 | 三个预设 + 常用 12 项 + 高级参数折叠 |
| 外观 | 主题（跟随系统/浅色/深色）、强调色、背景（纯色/链接/本地图片）、组件透明度、圆角、背景遮罩、底栏样式、性能模式 |
| 关于 | 版本、作者、反馈邮箱、复制诊断、写邮件、仓库地址 |

底栏是浮动的**液态玻璃**胶囊（毛玻璃 + 高光 + 会滑动的药丸），可在外观页切成通栏长条。

**卡顿处理**：卡片不再使用 `backdrop-filter`，模糊只保留在底栏；状态轮询 20 秒、日志 60 秒，
内容没变就不重写 DOM；低端机可以在外观页打开「性能模式」，一次性关掉模糊、过渡动画和高光。

日志页直接读取模块日志文件，带路径、大小、行数与最近 120 行；「自检」会输出
路径 / 权限 / 守护引擎 / helper 探针 / 内核 / SELinux / 配置状态，反馈时一并复制即可。

外观配置会写到 `/data/adb/cirno_reclaim/webui/theme.conf`（本地图片只保存在 WebView）。

> 旧版本（v2.0.0）的 WebUI 只有「概览/设置/反馈」三页，日志区在配置读取失败时会空白；
> v2.2.2 已改为四页并直接读取日志文件。

诊断信息包括：机型、Android / 内核版本、root 方案、守护状态、pageout 可用性、内存与 swap、配置、统计、最近 40 行日志。

---

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
