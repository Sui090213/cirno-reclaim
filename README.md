<div align="center">

# Cirno Reclaim Hybrid
此仓库已经废弃，请到新仓库
https://github.com/Sui090213/CirnoRecyclePlus

**把「冻结但不释放」的后台内存真正拿回来，同时把前台应用的内存压下去**

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Android 12+](https://img.shields.io/badge/Android-12%2B-3DDC84?logo=android&logoColor=white)](#环境要求)
[![Magisk](https://img.shields.io/badge/Magisk-24%2B-00AF9C)](https://github.com/topjohnwu/Magisk)
[![KernelSU](https://img.shields.io/badge/KernelSU-supported-4B8BBE)](https://github.com/tiann/KernelSU)
[![APatch](https://img.shields.io/badge/APatch-supported-8A2BE2)](https://github.com/bmax121/APatch)

Magisk / KernelSU / APatch · Android 12+ · cgroup v2 · GPL-3.0

作者：**flyingr** · ColorOS 17 适配致谢：**yishisanren** · 反馈：**asui20090213@outlook.com**

</div>

---

> **状态**：v2.3.4（双平台适配 + 低功耗守护 + 液态底栏）。已通过 POSIX shell 静态检查、`node --check`、
> 配置解析与打包结构校验，**仍未在全部机型验证**；本版没有真机功耗实测数据。
> 首次刷入默认 `dry_run=1`、`zram_enable=0` 演练，先观察一轮；
> 升级安装默认保留已有参数，只更新 `device_profile`。
> 想先想好回滚方式（`touch /data/adb/modules/cirno_reclaim/disable` 后重启），
> 详见 [RELEASE_NOTES-v2.3.4.md](RELEASE_NOTES-v2.3.4.md)。
>
> 审计与已知风险见 [SECURITY.md](SECURITY.md) 与 [docs/SECURITY-AUDIT.md](docs/SECURITY-AUDIT.md)。

## 这是什么

这是 [Cirno](https://github.com/Freezer-Team/Cirno) 冻结器的**配套内存管理模块**，由两个方向合并而来：

| 来源 | 贡献 |
|---|---|
| **cirno-reclaim**（由 Cirno 派生） | 冻结进程回收引擎、前台舒缓、KsuWebUI、安全模型 |
| **HybridRAM**（Razal） | zram + swapfile 混合交换、VM 参数调优与回写思路 |
| **v2.0.0-coloros.1**（yishisanren，基于 flyingr v2.0.0） | ColorOS 17 适配：先压缩后结束、双 cgroup 布局、冻结态直接结束、OEM zram 保护、`cirno_pageout` 计量修正（v2.3.0 合并） |

合并后由 **flyingr** 维护，脚本全部重写并统一到一套配置里，不再需要装两个模块互相打架。

一句话分工：

- **Cirno** 负责冻结后台应用；
- **本模块**负责把冻结进程占着的内存真正还给系统，并且让前台应用主动吐出缓存；
- **zram / swap / VM 调参**负责让「换出」这件事本身更快、更少卡顿。

从 v2.3.0 起，模块会按系统套用不同的**档案**（HyperOS / ColorOS / 通用）。
安装时可以用音量键选，也可以不按让它自动识别；两套档案的差异见
[docs/HYPEROS-COLOROS.md](docs/HYPEROS-COLOROS.md)。

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

- `cirno_daemon` 用单调时钟调度，按 `heartbeat_sec`（默认 45 秒）写心跳；子进程有硬超时，
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

## v2.3.0：双平台档案与低功耗守护

> v2.3.4 在这一版基础上只做加法：修掉 WebUI 开关回弹、底栏换成真正的液态玻璃折射
> （开关可关）、守护再降一档功耗（nice 19 / IO idle、空闲放宽到 60~90 秒、写盘减半），
> 细节见 [CHANGELOG.md](CHANGELOG.md) 的 v2.3.4 一节。

### 守护进程为什么更省电

v2.2.2 的 C++ 守护有几处耗电根因：每秒一次的主循环轮询、内存健康时也无条件 fork 回收脚本、
`boot_delay` 没生效、前台舒缓没有压力门控、每次 fork 都写日志。v2.3.0 重写了调度部分：

- **事件驱动睡眠**：以「心跳 / 内存压力探测 / 日志轮转」三类事件决定唤醒点，
  睡到最近的那个事件再醒，不再每秒轮询；回收 / 大进程检查 / 前台舒缓的计时器在这些
  唤醒点顺手比较，不额外唤醒；
- **内存压力门控**：每次要跑子进程之前，守护自己读 `/proc/meminfo` 和 `/proc/pressure/memory`，
  只有「可用内存低于阈值或 PSI 超标」才跑回收；连续多次不紧张后探测周期逐步放宽
  （最多到 60 秒），一紧张立刻恢复；
- `boot_delay` 真正生效：按系统 uptime 判断，开机后 uptime 未到 `boot_delay` 就不跑任何回收；
  被 watchdog 重新拉起时 uptime 早已超过，不会重复等一遍；
- 心跳从每 5 秒一次改为 **45 秒**一次（`heartbeat_sec`）；
- 不再给每次 spawn/exit 写日志，只记录启动、退出、超时、错误、配置重载和
  「紧张 / 不紧张」状态切换。

守护现在会统计自己的开销，`sh /data/adb/modules/cirno_reclaim/bin/cirno_daemon --status` 里可以直接看：

| 字段 | 含义 |
|---|---|
| `wakeups` | 累计唤醒次数（旧版空闲时约 60 次/分钟，新版空闲约 1.5~3 次/分钟） |
| `probes` | 内存压力探测次数 |
| `cpu_ms` | 守护自身累计 CPU 时间（`getrusage` 的 utime+stime），**验证功耗最硬的指标** |
| `tight` / `avail` / `psi` | 当前是否判定紧张、可用内存、PSI |
| `uptime` | 守护已运行秒数 |

也可以用 `sh /data/adb/modules/cirno_reclaim/bin/ctl.sh status --json`（或 `info` / `snapshot`）
看同样的数据，或直接 `cat /data/adb/cirno_reclaim/state/cpp.stats`。
日志里 `cpp-daemon: pressure TIGHT` / `relaxed` 记录紧张与放松的切换频率，正常待机应该很少出现。

> 以上是调度层修复，**本版没有真机功耗实测数据**；实际省电幅度取决于 ROM 与用法。
> `daemon_engine=shell` 仍沿用原来的调度方式。

### 先压后杀（`reclaim_order=pageout_first`）

默认回收顺序改成**先把冻结应用压进 zram（含 ART 堆），还不够才结束进程**：

- 内存紧张时先对冻结进程做页换出，达到目标就停，一个都不杀，切回后台应用不用重开；
- 页换出仍然不够时，才按 PSS 从大到小结束进程；
- 想恢复旧行为（先杀、杀完再换出）设 `reclaim_order=kill_first`。

### 双平台档案（HyperOS / ColorOS）

| 档案 | 适用 | 关键差异 |
|---|---|---|
| `hyperos` | 小米 / 红米 / POCO（HyperOS、MIUI） | `interval=20`、`vm_tune=1`（只写 sysctl）、`deep_pageout_max_mb=192`、`app_reclaim_interval=60`、排除 `com.miui.*` / `com.xiaomi.*` / `com.mi.*` |
| `coloros` | OPPO / OnePlus / realme（ColorOS、OPlus） | `interval=15`、`vm_tune=0`（不动系统内存参数）、`deep_pageout_max_mb=256`、`app_reclaim_interval=45`、排除 `com.oplus.*` / `com.coloros.*` / `com.heytap.*` / `com.oppo.*` / `com.nearme.*` / `com.finshell.*` |
| `generic` | 其他 ROM | 不覆盖任何值，只把 `device_profile=generic` 记下来 |

两套档案都默认 `zram_enable=0`、`swapfile_enable=0`、`reclaim_order=pageout_first`、
`relief_gate=1`。切换命令与 FAQ 见 [docs/HYPEROS-COLOROS.md](docs/HYPEROS-COLOROS.md)。

### OEM zram 保护与双 cgroup 布局

- **不重建 OEM 的 zram**：HyperOS「内存扩展」、ColorOS 的 zram 都由系统守护进程管理。
  档案里 `zram_enable=0`；在 HyperOS / ColorOS 上即使手动改回 1，只要 `zram_disksize_mb=0`
  （自动）也会被跳过，不会 reset / mkswap。只有你显式设置 `zram_disksize_mb>0` 时才允许接管
  （`generic` ROM 没有 OEM 自管判断，`disksize=0` 仍按自动大小处理）；
- **两种 cgroup 布局都认**：`apps/uid_*/pid_*` 与 `uid_*/pid_*`，
  并用 `cgroup.events` 判断实际冻结状态（含 uid 层冻结），不再只看 `cgroup.freeze`；
- **冻结态直接结束**：cgroup v2 冻结的进程可以收到 `SIGKILL`，不再先解冻等 1 秒；
  只有杀不死时才回退到解冻重试。

---

## 安装

### 环境要求

- Android 12+（需要 cgroup v2 的 per-pid freezer，即 Cirno 本身的要求）；
- Magisk 24+ / KernelSU 0.6+ / APatch；
- 建议同时安装并启用 Cirno 本体（否则 `only_frozen=1` 时没有可回收对象，可改成 `0`）；
- 前台页换出额外需要：arm64、内核支持 `pidfd_open` + `process_madvise`（常见于 5.10+ GKI）、有 zram 或 swap。
  本包的 arm64 helper 已内置（静态链接，非 arm64 设备安装时自动移除）。

### 步骤

1. 下载 `Cirno-Reclaim-Hybrid-v2.3.4.zip`；
2. 在 Magisk / KernelSU / APatch 里刷入。刷入过程中会问你是哪个系统，**8 秒内**按音量键选择：
   - **音量上** → HyperOS / MIUI（小米）；
   - **音量下** → ColorOS / realmeUI / OxygenOS；
   - **不按**（或读不到按键设备）→ 自动检测；
3. 重启。首次开机自动套用对应档案（`profile_bootstrap`）；
4. KernelSU 用户：模块详情 → 打开 WebUI；Magisk 用户用终端或「操作」按钮。

刷入日志里会同时打印「检测到的系统」，刷完也可以随时用 `ctl.sh profile` 查看或切换
（见 [docs/HYPEROS-COLOROS.md](docs/HYPEROS-COLOROS.md)）。

> 升级安装不会覆盖 `/data/adb/cirno_reclaim/config.conf`；新增的配置项会自动补默认值。
> 升级时**不按音量键** = `keep`：只更新 `device_profile` 为检测结果，你已有的参数不动；
> 只有按了键才会套用对应档案并覆盖档案里列出的键。
>
> 想跳过交互（脚本化刷入）：安装前设置环境变量
> `CR_PROFILE=hyperos|coloros|generic`（也可设 `auto`，表示按检测结果套用），优先级最高。
> 识别不出的 ROM 会落到 `generic`（不覆盖任何参数），不会强行套错档案。

### 首次使用

v2.3.0 起**全新安装默认 `dry_run=1`**：只在日志里记录本来会做什么，不压缩、不结束进程。
先观察一两天，在 WebUI 或配置里关掉「演练模式」并保存，才会真正动手。

### 从 cirno-reclaim 升级

模块 id 仍然是 `cirno_reclaim`，直接覆盖刷入即可，配置和日志位置不变。

---

## 小米 / HyperOS 注意

安装时选「音量上」或自动检测识别为 HyperOS，会套用 `hyperos` 档案。

- **内存扩展**：HyperOS 的「内存扩展」本身就是 zram，开机时已被 `swapon`。
  `hyperos` 档案默认 `zram_enable=0`，模块**不会重建**它；即使手动把 `zram_enable` 改回 1，
  只要 `zram_disksize_mb=0`（自动）也会被跳过，不会 reset / mkswap。
- **vm_tune**：`hyperos` 档案为 `1`，但只写 sysctl（`swappiness` 等），不碰 zram 设备。
- **包名保护**：默认排除 `com.miui.*`、`com.xiaomi.*`、`com.mi.*`。
- **省电策略**：把 KernelSU / Magisk 管理器、以及 Cirno 设为「无限制」，否则后台被杀时
  守护进程会被连带带走。即使被杀，`watchdog` 也会拉回，但会更耗电、日志里出现 `WATCHDOG:` 行。
- **前台识别**：HyperOS 仍然输出 `topResumedActivity`。如果日志出现
  `APP RELIEF skip: cannot detect foreground package`，用
  `dumpsys window | grep mCurrentFocus` 手工确认格式，再把输出发到反馈邮箱。
- **oom_score_adj**：小米的缓存进程一般就是 900，和默认 `min_oom_score_adj=900` 一致，不用改。
- 不要开 `allow_system_uid=1`；HyperOS 上系统进程被回收的后果比原生更明显。

## OPPO / ColorOS / realme 注意

安装时选「音量下」或自动检测识别为 ColorOS，会套用 `coloros` 档案。

- **内存扩展**：ColorOS 的 zram 带写回存储、由系统守护进程管理，**不要用本模块接管重建**。
  `coloros` 档案里 `zram_enable=0`，`vm_tune=0`（不动系统内存参数）；
- **包名保护**：默认排除 `com.oplus.*`、`com.coloros.*`、`com.heytap.*`、`com.oppo.*`、
  `com.nearme.*`、`com.finshell.*`；
- **回收节奏**：`coloros` 档案的 `interval=15`、`app_reclaim_interval=45` 比 HyperOS 档案更积极，
  单次深回收上限也更大（256MB）；
- **诊断**：`ctl.sh diag` 会输出 ColorOS 版本 / oplusrom、cgroup 布局与冻结计数、
  前台包、zram 详情、memcg、psi 等；`ctl.sh diagfile` 会把它写成
  `/sdcard/Download/cirno-diag-<时间>.txt`（WebUI 剪贴板不可用时用这个）；
- **前台识别**：检测不到前台包时同样看 `APP RELIEF skip: cannot detect foreground package`，
  把 `dumpsys window | grep mCurrentFocus` 的结果一并发来。

两套档案的完整差异、识别与手动切换见 [docs/HYPEROS-COLOROS.md](docs/HYPEROS-COLOROS.md)。

---

## 三种预设

WebUI「场景」页顶部，或命令行：

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

> 预设和系统档案是两个维度：预设只改回收额度 / `interval` / `reclaim_order` 等键，
> 不会改 `device_profile`；但两者都包含 `interval`，**以最后一次操作为准**。
> 想固定档案值，先选预设，最后再套一次档案。

---

## 两条回收路径

### 后台回收（会结束进程）

每轮：

1. 判断是否需要动手：`MemAvailable < 阈值`，或 PSI 超过 `psi_some_avg10`，或单个冻结进程 PSS ≥ `high_pss_mb`；
2. 枚举冻结进程（优先走 cgroup，必要时回退扫 `/proc/<pid>/`），只保留：
   - 应用 UID（`uid % 100000` ∈ `10000..19999`）；
   - `oom_score_adj >= 900`（缓存级）；
   - 实际冻结（`cgroup.events`，含 uid 层冻结；默认要求）；
   - 非前台、不在保护名单、命中 include 名单；
   - PSS ≥ `min_process_mb`；
   - 已冻结 ≥ `min_frozen_min` 分钟；
3. `reclaim_order=pageout_first`（默认）时，先按 PSS 从大到小把冻结进程的匿名页换出
   （含 ART 堆），达到目标就停；`kill_first` 则跳过这一步；
4. 页换出后还不够，才按 PSS 从大到小结束进程：冻结态直接 `SIGKILL`，
   杀不死才回退解冻重试；每步之后都复测可用内存；
5. 达到目标 / 单轮上限 / 每小时上限就停；最后才考虑 `drop_caches`。

日志示例：

```text
DEEP pid=12345 pkg=com.example.game pss=820MB pageout=192MB
RECLAIM pid=23456 pkg=com.example.app pss=210MB age=420s freed=180MB avail=1310MB mode=pid
```

### 前台舒缓（不结束进程）

`app_relief.sh` 对当前前台包：

1. 汇总该包所有进程的 PSS / 线程数；
2. 超过 `app_pss_mb` 时，对每个进程发 `am send-trim-memory <pid> <level>`；
3. 若 helper 可用，再按 PSS 比例分配预算，分 `app_pageout_passes` 轮做 `MADV_PAGEOUT`；
4. 复测 PSS 和可用内存，写进日志和 WebUI。

`relief_gate=1`（默认）时，自动舒缓只在内存紧张 / PSI 超标时执行；手动
`ctl.sh apprelief --force` 不受限制。这样内存充裕时不会主动去换出正在用的应用。

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
| `dry_run` | `1` | 只记录不动手（全新安装默认演练） |
| `device_profile` | `generic` | 系统档案：`hyperos` / `coloros` / `generic`，由安装或开机套用 |
| `interval` | `20` | 守护探测周期（秒），守护会按内存压力自适应放宽 |
| `boot_delay` | `90` | 开机后等待（本版起真正生效） |
| `log_max_kb` | `512` | 日志上限 |
| `profile` | `balanced` | 预设标记 |

`device_profile` 不是随便写的标记：`ctl.sh profile apply` 会按档案覆盖
`interval` / `vm_tune` / `zram_enable` / `swapfile_enable` / `reclaim_order` /
`deep_pageout_max_mb` / `app_reclaim_interval` / `app_reclaim_cooldown` /
`relief_gate` / `exclude_packages` 这些键。只改 `device_profile` 一行不会让参数跟着变。

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
| `deep_reclaim` / `deep_pageout_max_mb` | `1` / `192` | 深回收（`pageout_first` 下同时是首轮页换出上限） |
| `reclaim_order` | `pageout_first` | 先页换出、不够再结束；`kill_first` = 旧顺序 |
| `drop_caches` / `drop_caches_cooldown` | `0` / `1800` | 清页缓存 |
| `allow_system_uid` | `0` | 允许系统 UID，别开 |

### 前台舒缓

| 键 | 默认 | 说明 |
|---|---:|---|
| `app_reclaim` | `1` | 启用 |
| `relief_gate` | `1` | 1 = 只在内存紧张 / PSI 超标时自动舒缓 |
| `app_pss_mb` | `900` | 触发阈值（全部进程 PSS 之和） |
| `app_reclaim_interval` / `app_reclaim_cooldown` | `60` / `90` | 周期 / 冷却 |
| `app_trim_level` | `RUNNING_LOW` | `MODERATE` / `LOW` / `CRITICAL` |
| `app_trim_all_pids` | `1` | 所有进程都 trim |
| `app_pageout` | `1` | 启用页换出 |
| `app_pageout_max_mb` / `app_pageout_passes` | `192` / `3` | 预算 / 轮数 |
| `app_proc_reclaim` | `0` | OEM 的 `/proc/<pid>/reclaim` |

### VM / 交换

| 键 | 默认 | 说明 |
|---|---:|---|
| `vm_tune` | `1` | 总开关（只写 sysctl） |
| `zram_enable` / `zram_disksize_mb` | `0` / `0` | 默认不接管 OEM zram；显式设大小才会重建 |
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
| `heartbeat_sec` | `45` | C++ 守护写心跳的间隔，实际夹在 10..min(120, `heartbeat_timeout/2`)；调小 `heartbeat_timeout` 会同时压低它的上限 |
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
sh $ctl snapshot          # 状态 + 设备信息一次返回（WebUI 用）
sh $ctl info              # 设备 + 引擎 + wakeups / cpu_ms
sh $ctl profile           # 当前档案 / 检测到的系统（k=v）
sh $ctl profile list      # 可用档案 + 当前 / 检测结果（JSON）
sh $ctl profile detect    # 只输出检测结果（hyperos / coloros / generic）
sh $ctl profile apply coloros   # 手动套用档案
sh $ctl scan              # 候选列表
sh $ctl run               # 立即回收一次
sh $ctl apprelief --force # 立即舒缓前台
sh $ctl log 120           # 日志
sh $ctl diag              # 诊断信息（反馈用）
sh $ctl doctor            # 自检（含 [profile] / [power] 段）
sh $ctl preset aggressive # 预设
sh $ctl set mem_low_mb=1200 max_kills_per_run=6
sh $ctl restart | start | stop
```

`profile apply` 会覆盖该档案包含的参数（不是只改 `device_profile` 一行），
其它参数保留；建议在 WebUI「场景 → 系统适配」里点选或先备份配置。详细输出示例见
[docs/HYPEROS-COLOROS.md](docs/HYPEROS-COLOROS.md)。

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
| 控制台 | 圆环仪表（可用 %）、可用/Swap、累计回收与释放、守护引擎与档案（`device_profile` / 回收顺序 / `relief_gate`）、页换出状态、立即回收、舒缓前台、扫描、重启、日志、自检 |
| 场景 | 三个预设 + **系统适配**卡片（HyperOS / ColorOS / 通用，显示「检测到：<rom>」）+ 常用 12 项（开关行内显示保存中/已保存/失败）+ 高级参数折叠 + **设置保存诊断** |
| 外观 | 主题（跟随系统/浅色/深色）、强调色、背景（纯色/链接/本地图片）、组件透明度、圆角、背景遮罩、底栏样式、**液态玻璃折射**开关、性能模式 |
| 关于 | 版本、作者、反馈邮箱、复制诊断、写邮件、仓库地址 |

「系统适配」卡片点击后会弹确认（套用档案会覆盖该档案包含的参数，其它参数保留），确认后调用
`ctl.sh profile apply <名字>` 并刷新状态。当前档案的判定规则与两套档案的差异见
[docs/HYPEROS-COLOROS.md](docs/HYPEROS-COLOROS.md)。

场景页的配置表单也补了三项：`reclaim_order`（回收顺序）、`relief_gate`（舒缓门控）、
`heartbeat_sec`（心跳间隔）。

底栏是浮动的**液态玻璃**胶囊，外观页可以单独开关「液态玻璃折射」：
开启时滑块会用 `backdrop-filter: url(<data:image/svg+xml 位移滤镜>)` 真实折射底下的内容
（滤镜数学移植自 MIT 项目 [nikdelvin/liquid-glass](https://github.com/nikdelvin/liquid-glass)，
声明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)）。
Android WebView 不支持 `backdrop-filter: url()` 时会自动降级为普通高光药丸（外观页会显示「不支持」），
性能模式下也一律禁用。

**卡顿处理**：卡片不使用 `backdrop-filter`，折射只作用在几十像素的滑块上；状态轮询 20 秒、日志 60 秒，
内容没变就不重写 DOM；低端机可以在外观页打开「性能模式」，一次性关掉折射、流动光斑、过渡动画和高光。

日志页直接读取模块日志文件，带路径、大小、行数与最近 120 行；「自检」会输出
路径 / 权限 / 守护引擎 / helper 探针 / 内核 / SELinux / 配置状态，以及新增的
`[profile]`（档案 / 回收顺序 / 门控 / OEM zram）和 `[power]`
（`interval` / heartbeat / `boot_delay` / cpp stats：`wakeups`、`probes`、`cpu_ms`）两段。

外观配置会写到 `/data/adb/cirno_reclaim/webui/theme.conf`（本地图片只保存在 WebView）。

> 旧版本（v2.0.0）的 WebUI 只有「概览/设置/反馈」三页，日志区在配置读取失败时会空白；
> v2.2.2 已改为四页并直接读取日志文件。

诊断信息包括：机型 / SoC、Android / 内核版本、ROM 与 oplusrom / ColorOS 判定、root 方案、
守护状态、档案与 cgroup 布局 / 冻结计数、前台包、pageout 可用性、zram / swap、vm 参数、
memcg、psi、配置、统计、候选扫描前 15 行与最近 40 行日志。

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
git tag v2.3.4 && git push origin v2.3.4
```

推送 tag 后 `.github/workflows/release.yml` 会自动：编译两个原生组件 → 跑 lint → 打包 →
上传 artifact → 创建 Release（附带 zip 与 `CHECKSUMS.txt`）。

发布前请逐项过一遍 [SECURITY.md](SECURITY.md) 第 7 节的检查清单。
三种上传方式（网页 / git / gh）与仓库设置见 [docs/PUBLISH.md](docs/PUBLISH.md)，
Release 正文可直接用 [RELEASE_NOTES-v2.3.4.md](RELEASE_NOTES-v2.3.4.md)。

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
├── profiles/
│   ├── hyperos.conf     # HyperOS / MIUI 档案（只写要覆盖的键）
│   └── coloros.conf     # ColorOS / OPlus 档案
├── bin/
│   ├── common.sh        # 日志 / 内存 / PSS / 冻结检测 / 配置准入 / ROM 识别
│   ├── vm_tune.sh       # zram + swapfile + sysctl（含 OEM zram 保护）
│   ├── reclaim.sh       # 后台回收引擎（支持先压后杀）
│   ├── app_relief.sh    # 前台舒缓（支持 relief_gate 压力门控）
│   ├── daemon.sh        # shell 守护（兼容回退）
│   ├── watchdog.sh      # 保活看门狗
│   ├── ctl.sh           # 命令行 / JSON API（含 profile 子命令）
│   ├── cirno_daemon     # C++ 守护（默认引擎，事件驱动）
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
│   ├── COOLAPK.md
│   ├── HYPEROS-COLOROS.md
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
├── RELEASE_NOTES-v2.3.4.md
└── SECURITY.md
```

运行时数据：

```text
/data/adb/cirno_reclaim/
├── config.conf
├── daemon.pid
├── watchdog.pid
└── state/          # 心跳、统计、冻结时长、守护重启次数、profile.applied
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

**场景页开关点了保存后又自己弹回去**

先看开关行内是不是显示「失败」：

- 显示「失败」→ 保存确实没成功。打开场景页最下面的「设置保存诊断」：
  - 点 **「保存诊断到文件」**（推荐，不依赖剪贴板）：写到
    `/sdcard/Download/cirno-diag-<时间>.txt`，内容含模块侧诊断 + WebUI 侧诊断
    （两条保存通道的命令、`errno`、`stdout` / `stderr`、界面缓存）以及最近 12 条
    `config write` / `WEBUI save` 日志，把这个文件发反馈邮箱即可定位；
  - 「核对配置」会把配置文件重新读一遍、逐项对比界面开关；
  - 「复制诊断」在剪贴板可用时可直接复制；不可用会自动落盘并提示路径；
- 不显示「失败」但还是回弹 → 多半是 WebView 缓存了旧的 `app.js`，强制停止管理器后重开。

v2.3.4 起保存默认走参数形式（不依赖 stdin / 管道），一条失败会自动换另一条，两条都失败才回滚；
`ctl.sh diagfile` 也可以直接在终端把诊断落盘。

**守护一直重启**

看日志里 `WATCHDOG:` 行；如果 daemon 启动即退出，多半是配置语法错误——`ctl.sh` 会保留上一份配置并记 `config.conf syntax error`。

**担心守护耗电 / 想看唤醒次数和 CPU 开销**

```sh
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh info
sh /data/adb/modules/cirno_reclaim/bin/cirno_daemon --status
cat /data/adb/cirno_reclaim/state/cpp.stats
```

关注三个数：`wakeups`（累计唤醒次数）、`probes`（压力探测次数）、
`cpu_ms`（守护自身累计 CPU 时间）。正常待机一小时 `cpu_ms` 应该只有几百毫秒；
`tight` 表示当前是否判定为内存紧张。如果 `tight` 长期为 1 而可用内存并不低，
先检查 `mem_low_mb` / `mem_low_pct` / `psi_some_avg10` 是不是设得太激进。
日志里出现 `RECLAIM start` 就代表真的跑了回收，没有这行说明门控在正常工作；
`cpp-daemon: pressure TIGHT` / `relaxed` 的切换频率则反映门控抖动程度。

**系统档案选错了 / 识别成 generic**

```sh
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh profile
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh profile list
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh profile apply hyperos   # 或 coloros / generic
```

检测用的属性可以用 `getprop ro.mi.os.version.name`、`getprop ro.build.version.oplusrom` 手工核对。
如果确认识别错误，把 `ctl.sh diag` 的输出发到反馈邮箱。

**升级后参数被改了？**

升级安装默认 `keep`，只更新 `device_profile`，不应改其它参数；只有刷入时按了音量键、
或手动执行过 `profile apply`，才会套用档案并覆盖档案里的键。
不确定时对比 `/data/adb/cirno_reclaim/config.conf` 与 `profiles/*.conf`。

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
- **v2.0.0-coloros.1**（yishisanren，基于 flyingr 的 v2.0.0）：ColorOS 17 适配版，
  本版合并了其中先压缩后结束、双 cgroup 布局、冻结态直接结束、OEM zram 保护、
  `cirno_pageout` 计量修正、增强诊断等改进；原作者署名与版权保留；
- **HybridRAM**（Razal，Razal1_1）：zram / swapfile 混合交换与 VM 回写思路，代码为本项目重写；
- [KernelSU](https://github.com/tiann/KernelSU)、[Magisk](https://github.com/topjohnwu/Magisk)、[APatch](https://github.com/bmax121/APatch)：模块运行环境；
- [Zig](https://ziglang.org/) / musl：arm64 helper 交叉编译。

如果你分发修改后的版本，请保留上述署名与许可证。

<div align="center">

**Cirno Reclaim Hybrid** · 让冻结真正等于省内存

</div>
