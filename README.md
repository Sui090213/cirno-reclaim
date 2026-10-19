<div align="center">

# Cirno Reclaim Hybrid

**把「冻结但不释放」的后台内存真正拿回来，同时把前台应用的内存压下去**

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Android 12+](https://img.shields.io/badge/Android-12%2B-3DDC84?logo=android&logoColor=white)](#环境要求)
[![Magisk](https://img.shields.io/badge/Magisk-24%2B-00AF9C)](https://github.com/topjohnwu/Magisk)
[![KernelSU](https://img.shields.io/badge/KernelSU-supported-4B8BBE)](https://github.com/tiann/KernelSU)
[![APatch](https://img.shields.io/badge/APatch-supported-8A2BE2)](https://github.com/bmax121/APatch)

Magisk / KernelSU / APatch · Android 12+ · cgroup v2 · GPL-3.0

作者：**flyingr** · 反馈：**asui20090213@outlook.com**

</div>

---

> **状态**：v2.2.2。已通过 POSIX shell 静态检查、`node --check`、配置解析与打包结构校验，
> **尚未在真机上完整验证**。首次刷入建议先设 `dry_run=1`、`zram_enable=0` 观察一轮，
> 并先想好回滚方式（`touch /data/adb/modules/cirno_reclaim/disable` 后重启）。
>
> 审计与已知风险见 [SECURITY.md](SECURITY.md) 与 [docs/SECURITY-AUDIT.md](docs/SECURITY-AUDIT.md)。

## 这是什么

这是 [Cirno](https://github.com/Freezer-Team/Cirno) 冻结器的**配套内存管理模块**，由两个方向合并而来：

| 来源 | 贡献 |
|---|---|
| **cirno-reclaim**（由 Cirno 派生） | 冻结进程回收引擎、前台舒缓、KsuWebUI、安全模型 |
| **HybridRAM**（Razal） | zram + swapfile 混合交换、VM 参数调优与回写思路 |

合并后由 **flyingr** 维护，脚本全部重写并统一到一套配置里，不再需要装两个模块互相打架。

一句话分工：

- **Cirno** 负责冻结后台应用；
- **本模块**负责把冻结进程占着的内存真正还给系统，并且让前台应用主动吐出缓存；
- **zram / swap / VM 调参**负责让「换出」这件事本身更快、更少卡顿。

---

## 相对上游改了什么

这一版重点修的就是实际用起来最难受的四个点。

### 1. 回收太保守、每次只回收一点点

| 改动 | 说明 |
|---|---|
| 阈值双轨 | `mem_low_mb` 与 `mem_low_pct` 取较大值，12GB 机器不会再用 8GB 的绝对值 |
| PSI 触发 | 读 `/proc/pressure/memory` 的 `some avg10`，MemAvailable 看着还行但系统已经在卡时也会回收 |
| 多轮迭代 | `max_rounds` 分批重扫，而不是扫一次就结束 |
| 提高默认额度 | 单轮 4 个 / 每小时 20 个（上游 3 / 12），冻结 5 分钟即可回收（上游 10） |
| 真正按 PSS 排序 | 从大到小回收，每次回收后立刻复测可用内存，达到目标才停 |
| 深回收 | 杀完还不够时，把冻结进程的匿名页换出（不杀进程） |

### 2. 前台回收效果有限

| 改动 | 说明 |
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

- Android 12+（需要 cgroup v2 的 per-pid freezer，即 Cirno 本身的要求）；
- Magisk 24+ / KernelSU 0.6+ / APatch；
- 建议同时安装并启用 Cirno 本体（否则 `only_frozen=1` 时没有可回收对象，可改成 `0`）；
- 前台页换出额外需要：arm64、内核支持 `pidfd_open` + `process_madvise`（常见于 5.10+ GKI）、有 zram 或 swap。
  本包的 arm64 helper 已内置（静态链接，非 arm64 设备安装时自动移除）。

### 步骤

1. 下载 `Cirno-Reclaim-Hybrid-v2.2.2.zip`；
2. 在 Magisk / KernelSU / APatch 里刷入；
3. 重启；
4. KernelSU 用户：模块详情 → 打开 WebUI；Magisk 用户用终端或「操作」按钮。

> 升级安装不会覆盖 `/data/adb/cirno_reclaim/config.conf`；新增的配置项会自动补默认值。

### 从 cirno-reclaim 升级

模块 id 仍然是 `cirno_reclaim`，直接覆盖刷入即可，配置和日志位置不变。

---

## 小米 / HyperOS 注意

- **内存扩展**：HyperOS 的「内存扩展」本身就是 zram，开机时已被 `swapon`，
  模块检测到就会**跳过重建**（`zram_enable=1` 也不会动它）。想彻底不管 zram 就设 `zram_enable=0`。
- **省电策略**：把 KernelSU / Magisk 管理器、以及 Cirno 设为「无限制」，否则后台被杀时
  守护进程会被连带带走。即使被杀，`watchdog` 也会拉回，但会更耗电、日志里出现 `WATCHDOG:` 行。
- **前台识别**：HyperOS 仍然输出 `topResumedActivity`。如果日志出现
  `APP RELIEF skip: cannot detect foreground package`，用
  `dumpsys window | grep mCurrentFocus` 手工确认格式，再把输出发到反馈邮箱。
- **oom_score_adj**：小米的缓存进程一般就是 900，和默认 `min_oom_score_adj=900` 一致，不用改。
- 不要开 `allow_system_uid=1`；HyperOS 上系统进程被回收的后果比原生更明显。

---

## 三种预设

WebUI「设置」页顶部，或命令行：

```sh
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh preset aggressive
```

| | 保守 | 均衡（默认） | 激进 |
|---|---|---|---|
| 触发阈值 | 600MB / 6% | 800MB / 8% | 1600MB / 12% |
| 目标 | 900MB / 10% | 1200MB / 14% | 2200MB / 18% |
| 单轮 / 每小时 | 2 / 8 | 4 / 20 | 6 / 36 |
| 最短冻结 | 15 分钟 | 5 分钟 | 2 分钟 |
| 最小进程 | 96MB | 48MB | 32MB |
| 前台阈值 | 1200MB | 900MB | 700MB |
| 前台页换出 | 关 | 开 | 开（4 轮） |
| 深回收 / 清页缓存 | 关 / 关 | 开 / 关 | 开 / 开 |

「觉得回收太少」就先选**激进**跑一天；如果出现误杀或明显卡顿，再退回均衡。

---

## 两条回收路径

### 后台回收（会结束进程）

每轮：

1. 判断是否需要动手：`MemAvailable < 阈值`，或 PSI 超过 `psi_some_avg10`，或单个冻结进程 PSS ≥ `high_pss_mb`；
2. 扫描 `/proc/<pid>/`，只保留：
   - 应用 UID（`uid % 100000` ∈ `10000..19999`）；
   - `oom_score_adj >= 900`（缓存级）；
   - `cgroup.freeze=1`（默认要求）；
   - 非前台、不在保护名单、命中 include 名单；
   - PSS ≥ `min_process_mb`；
   - 已冻结 ≥ `min_frozen_min` 分钟；
3. 按 PSS 从大到小，**先解冻再结束**，每次回收后复测可用内存；
4. 达到目标 / 单轮上限 / 每小时上限就停；
5. 还不够就深回收（页换出），最后才考虑 `drop_caches`。

日志示例：

```text
RECLAIM pid=12345 pkg=com.example.app pss=210MB age=420s freed=180MB avail=1310MB mode=pid
```

### 前台舒缓（不结束进程）

`app_relief.sh` 对当前前台包：

1. 汇总该包所有进程的 PSS / 线程数；
2. 超过 `app_pss_mb` 时，对每个进程发 `am send-trim-memory <pid> <level>`；
3. 若 helper 可用，再按 PSS 比例分配预算，分 `app_pageout_passes` 轮做 `MADV_PAGEOUT`；
4. 复测 PSS 和可用内存，写进日志和 WebUI。

日志示例：

```text
APP RELIEF done pkg=com.ss.android.ugc.aweme pss=1120MB->860MB avail=900MB->1150MB pageout=176MB
```

> 页换出不杀进程、不杀线程，被换出的页在应用再次访问时由内核换回；代价是可能出现一次缺页。
> 如果换出后反而卡顿，把 `app_pageout=0`，只保留 trim。

---

## 配置

配置文件：`/data/adb/cirno_reclaim/config.conf`（`0600`，只应 root 修改）。

改完守护进程下一轮自动重读，也可以立即重启：

```sh
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh restart
```

### 通用

| 键 | 默认 | 说明 |
|---|---:|---|
| `enable` | `1` | 总开关 |
| `dry_run` | `0` | 只记录不动手 |
| `interval` | `15` | 守护周期（秒） |
| `boot_delay` | `90` | 开机后等待 |
| `log_max_kb` | `512` | 日志上限 |
| `profile` | `balanced` | 预设标记 |

### 后台回收

| 键 | 默认 | 说明 |
|---|---:|---|
| `mem_low_mb` / `mem_low_pct` | `800` / `8` | 触发阈值（取较大值） |
| `mem_target_mb` / `mem_target_pct` | `1200` / `14` | 目标（取较大值） |
| `psi_enable` / `psi_some_avg10` | `1` / `25` | PSI 压力触发 |
| `high_pss_mb` / `high_pss_interval` | `600` / `90` | 单进程大内存看门狗 |
| `max_kills_per_run` / `max_kills_per_hour` | `4` / `20` | 额度 |
| `max_rounds` | `4` | 单次最多几批 |
| `cooldown_sec` | `60` | 两次自动回收的间隔 |
| `min_process_mb` | `48` | 忽略小进程 |
| `min_frozen_min` | `5` | 最短冻结时间 |
| `min_oom_score_adj` | `900` | 只碰缓存级进程，别乱调 |
| `only_frozen` | `1` | 只回收已冻结进程 |
| `kill_mode` | `pid` | `pid` 精确结束 / `am` 结束整包后台 |
| `protect_foreground` | `1` | 保护前台 |
| `screen_off_only` | `0` | 只在息屏时回收 |
| `deep_reclaim` / `deep_pageout_max_mb` | `1` / `96` | 深回收 |
| `drop_caches` / `drop_caches_cooldown` | `0` / `1800` | 清页缓存 |
| `allow_system_uid` | `0` | 允许系统 UID，别开 |

### 前台舒缓

| 键 | 默认 | 说明 |
|---|---:|---|
| `app_reclaim` | `1` | 启用 |
| `app_pss_mb` | `900` | 触发阈值（全部进程 PSS 之和） |
| `app_reclaim_interval` / `app_reclaim_cooldown` | `45` / `90` | 周期 / 冷却 |
| `app_trim_level` | `RUNNING_LOW` | `MODERATE` / `LOW` / `CRITICAL` |
| `app_trim_all_pids` | `1` | 所有进程都 trim |
| `app_pageout` | `1` | 启用页换出 |
| `app_pageout_max_mb` / `app_pageout_passes` | `192` / `3` | 预算 / 轮数 |
| `app_proc_reclaim` | `0` | OEM 的 `/proc/<pid>/reclaim` |

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

sh $ctl status            # 人读状态
sh $ctl status --json     # JSON（WebUI 用）
sh $ctl scan              # 候选列表
sh $ctl run               # 立即回收一次
sh $ctl apprelief --force # 立即舒缓前台
sh $ctl log 120           # 日志
sh $ctl diag              # 诊断信息（反馈用）
sh $ctl preset aggressive # 预设
sh $ctl set mem_low_mb=1200 max_kills_per_run=6
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

- 邮箱：**asui20090213@outlook.com**
- WebUI「反馈」页可以一键复制诊断信息，粘贴进邮件即可；
- 也欢迎在 GitHub 提 Issue（附诊断信息更好定位）。

请尽量写明：机型、Android 版本、内核版本、root 方案、复现步骤、日志。

---

## 构建

```sh
# 1. 语法检查
python3 tools/lint_sh.py .
node --check webroot/app.js
# 可选：shellcheck -s sh bin/*.sh *.sh

# 2. 编译两个 arm64 原生组件（C helper + C++ 守护）
cd src && ./build.sh          # 需要 zig 0.13+（C++ 需要 zig c++）
                              # 或 CC=aarch64-linux-android24-clang ./build.sh 只编 C helper

# 3. 打包（模块 zip 根目录必须直接有 module.prop）
python3 tools/pack.py
```

`tools/pack.py` 的模块包只包含运行期文件 + `LICENSE` + 两个原生组件的源码，
不会把文档、构建脚本塞进刷入包；源码包（`--source`）保留全部文件。

不编译原生组件也能用：C++ 守护自动回退到 shell，前台只做 trim。

### 发布到 GitHub

```sh
python3 tools/lint_sh.py .        # 静态检查
node --check webroot/app.js       # WebUI 语法
python3 tools/pack.py             # 模块 zip  -> dist/
python3 tools/checksums.py        # SHA-256   -> dist/CHECKSUMS.txt
git tag v2.2.2 && git push origin v2.2.2
```

推送 tag 后 `.github/workflows/release.yml` 会自动：编译两个原生组件 → 跑 lint → 打包 →
上传 artifact → 创建 Release（附带 zip 与 `CHECKSUMS.txt`）。

发布前请逐项过一遍 [SECURITY.md](SECURITY.md) 第 7 节的检查清单。
三种上传方式（网页 / git / gh）与仓库设置见 [docs/PUBLISH.md](docs/PUBLISH.md)，
Release 正文可直接用 [RELEASE_NOTES-v2.2.2.md](RELEASE_NOTES-v2.2.2.md)。

---

## 目录结构

```text
Cirno-Reclaim-Hybrid/
├── module.prop
├── customize.sh
├── post-fs-data.sh
├── service.sh
├── uninstall.sh
├── action.sh
├── config.conf
├── bin/
│   ├── common.sh        # 日志 / 内存 / PSS / 冻结检测 / 配置准入
│   ├── vm_tune.sh       # zram + swapfile + sysctl
│   ├── reclaim.sh       # 后台回收引擎
│   ├── app_relief.sh    # 前台舒缓
│   ├── daemon.sh        # shell 守护（兼容回退）
│   ├── watchdog.sh      # 保活看门狗
│   ├── ctl.sh           # 命令行 / JSON API
│   ├── cirno_daemon     # C++ 守护（默认引擎）
│   └── cirno_pageout    # C 前台页换出 helper
├── src/
│   ├── cirno_daemon.cpp
│   ├── cirno_pageout.c
│   └── build.sh
├── webroot/
│   ├── index.html
│   ├── style.css
│   └── app.js
├── docs/
│   ├── PUBLISH.md
│   └── SECURITY-AUDIT.md
├── tools/
│   ├── pack.py          # 打包模块 zip
│   ├── lint_sh.py       # POSIX sh 静态检查
│   └── checksums.py     # 生成 SHA-256
├── .github/
│   ├── workflows/release.yml
│   ├── ISSUE_TEMPLATE/{bug_report.yml,config.yml}
│   └── PULL_REQUEST_TEMPLATE.md
├── .editorconfig
├── .gitattributes
├── .gitignore
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
├── README.md
├── RELEASE_NOTES-v2.2.2.md
└── SECURITY.md
```

运行时数据：

```text
/data/adb/cirno_reclaim/
├── config.conf
├── daemon.pid
├── watchdog.pid
└── state/          # 心跳、统计、冻结时长、守护重启次数
```

日志：`/data/adb/modules/cirno_reclaim/log/reclaim.log`

---

## 故障排查

**扫描结果一直是空的**

```sh
sh /data/adb/modules/cirno_reclaim/bin/reclaim.sh --scan
tail -n 120 /data/adb/modules/cirno_reclaim/log/reclaim.log
```

常见原因：Cirno 没在冻结、`oom_score_adj < 900`、冻结时间不够、PSS 太小、包在 `exclude_packages`、设备不是 per-pid cgroup 布局。

**回收了但可用内存没涨多少**

被回收进程可能大量使用共享页（PSS 会重复计算），或者刚被杀就被系统拉起来。看 `freed=` 和 `avail=` 差值，不要只看 PSS。

**前台舒缓没有效果**

日志里 `pss=1120MB->860MB` 说明有效；`->` 两边差不多说明应用不响应 trim，或者内核不支持 `process_madvise`（`pageout unavailable`）。

**WebUI 显示旧版本**

强制停止 KernelSU / KsuWebUI 后重开，或重启一次（WebUI 是静态文件，可能被 WebView 缓存）。

**守护一直重启**

看日志里 `WATCHDOG:` 行；如果 daemon 启动即退出，多半是配置语法错误——`ctl.sh` 会保留上一份配置并记 `config.conf syntax error`。

---

## 安全

- 只回收：应用 UID + `oom_score_adj>=900` + 已冻结 + 非前台 + 通过名单；
- 前台路径**永不结束进程**，只 trim / 页换出；
- 硬编码保护关键包（系统 UI、桌面、输入法、电话、GMS、root 管理器、Cirno）；
- **配置不是无条件 source**：逐行只接受 `KEY=VALUE`，值只允许安全字符集，
  不通过就拒绝加载并沿用旧值（详见 [SECURITY.md](SECURITY.md) 第 4 节）；
- 配置 `0600`、数据目录 `0700`、日志 `0600`、`umask 077`；
- 不上传任何数据、无遥测、无网络请求；
- 卸载时停止全部进程并删除 `/data/adb/cirno_reclaim`。

发布前必读的检查清单在 [SECURITY.md](SECURITY.md) 第 7 节，
逐版本的审计记录在 [docs/SECURITY-AUDIT.md](docs/SECURITY-AUDIT.md)。

---

## 许可证与致谢

本项目代码采用 **GPL-3.0-only**，见 [LICENSE](LICENSE)。

选择 GPL-3.0 而不是 MIT / Apache-2.0 的原因：

- 上游 [Cirno](https://github.com/Freezer-Team/Cirno) 本身是 GPL-3.0，配套模块采用同一协议最符合社区预期；
- 这是一个 root 模块，copyleft 能保证二次分发者继续公开修改，避免「改一改就闭源卖」；
- APatch / KernelSU / Magisk 生态里的同类模块普遍使用 GPL-3.0。

如果你需要把本项目用于闭源产品，请先联系作者讨论授权。

上游项目的版权与许可归各自作者所有：

- [Cirno](https://github.com/Freezer-Team/Cirno)：冻结器与 cgroup v2 freezer 思路（GPL-3.0）；
- **cirno-reclaim**：本项目的前身，提供了回收策略与安全模型的设计；本次实现依据其公开文档独立重写
  （原始压缩包内只有文档、没有脚本），未复制其源码；
- **HybridRAM**（Razal，Razal1_1）：zram / swapfile 混合交换与 VM 回写思路，代码为本项目重写；
- [KernelSU](https://github.com/tiann/KernelSU)、[Magisk](https://github.com/topjohnwu/Magisk)、[APatch](https://github.com/bmax121/APatch)：模块运行环境；
- [Zig](https://ziglang.org/) / musl：arm64 helper 交叉编译。

如果你分发修改后的版本，请保留上述署名与许可证。

<div align="center">

**Cirno Reclaim Hybrid** · 让冻结真正等于省内存

</div>
