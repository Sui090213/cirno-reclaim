# Changelog

本项目由 **cirno-reclaim**（由 Cirno 派生）与 **HybridRAM** 整合而来，作者 flyingr。

## v2.3.4 — 真机诊断定位：配置读取链路重做 + arm64 安装修复

版本号 `v2.3.4` / `versionCode 20304`。

拿到真机诊断文件（KernelSU + Android 15）后，定位到两个确定的 bug。

### 修复 1：KernelSU 上原生组件被安装脚本误删（严重）

诊断里是 `pageout: helper missing`、`cpp daemon: binary missing (engine = shell)`，
说明装完后 `bin/cirno_daemon` 与 `bin/cirno_pageout` **根本不在设备上**。
原因：`customize.sh` 用 `case "$_arch" in arm64)` 精确匹配，而管理器传的 `ARCH`
是 `arm64-v8a`，匹配失败就走进「非 arm64」分支，把两个二进制删了。
现在改成前缀匹配（`arm64*` / `aarch64*`），`ARCH` 为空时直接读 `ro.product.cpu.abi`。
**影响**：之前几版在 KernelSU / APatch 上其实一直跑的是 shell 守护，页换出完全没用上。

### 修复 2：「开关回弹」的真正原因 —— WebUI 读配置读空了

诊断显示保存其实**全部成功**：`config write: ok (N key(s))`、`errno=0`、`stdout={"ok":1}`，
配置文件的 `sh -n=ok`、可写、可读。但 WebUI 侧 `界面缓存: {}` ——
前端**读配置读成了空**，于是所有开关按「关」渲染；用户打开、切页面回来又按空配置渲染成关，
看起来就是「回弹」。写没问题，是**读**的链路有问题。

修法：

- 新增 `ctl.sh configjson`：把 `cfg_load()` **之后真正生效的值**输出成**单行 JSON**，
  WebUI 直接 `JSON.parse`，不再让前端解析带注释 / 行内注释 / 单引号的多行配置文本；
- `loadConfig()` 改成「先 `configjson`，失败再退回原文本解析」，老版 ctl 仍可用；
- 「保存设置」只提交**用户真正改过的字段**（脏标记）：表单没加载成功时，
  以前的实现会把空值写回去（诊断里就看到把 `exclude_packages` 写成空串，等于清空排除名单）；
- 诊断再增强：`--- config raw ---` 增加 `lines / bytes / md5`、头 4 行、键行数、
  前 6 个键行、末 3 行，以及 `configjson` 的实际输出；
  WebUI 侧诊断增加 `configLoaded / meta / keys`。

### 其他

- 修日志里 `vv2.3.3` 的双 v（`bin/daemon.sh`、`post-fs-data.sh`）。

## v2.3.3 — 诊断导出 + 剪贴板兜底 + 保存失败留痕

版本号 `v2.3.3` / `versionCode 20303`。

真机反馈：「诊断也复制失败了」。WebView 里剪贴板 API 经常不可用（非安全上下文、没权限、
`execCommand('copy')` 被拒），所以这一版的核心思路是 **不依赖剪贴板也能把信息带出来**。

### 新增

- `ctl.sh diagfile`：把完整诊断写成文件，依次尝试 `/sdcard/Download/`、
  `/storage/emulated/0/Download/`、`/sdcard/`、`/data/local/tmp/`，输出 JSON 路径；
- 场景页「设置保存诊断」新增 **「保存诊断到文件」**：把 ctl 侧诊断 + WebUI 侧诊断
  （保存通道、命令、errno、stdout / stderr、界面缓存、UA）一起追加进该文件；
- 「复制诊断」（场景页与关于页）都改成：剪贴板失败 → 自动落盘并提示路径；
- 诊断里新增配置文件自检：`config : <路径> (bytes, writable, readable, sh -n=ok|FAIL)`、
  data 目录可写性，以及最近 12 条 `config write` / `WEBUI save` 日志。

### 修复

- `copyText()`：以前 `navigator.clipboard.writeText` 被拒后**直接失败**，不会退回
  textarea + `execCommand` 的老办法；现在两级都试，且 textarea 强制 `user-select:text`；
- 诊断 `<pre>` 允许长按手动选择复制（`user-select:text` + `-webkit-touch-callout:default`），
  剪贴板彻底不可用时也能选中；
- `cfg_write_pairs()` 记录每次写配置的结果：成功 `config write: ok (N key(s))`，
  失败 `config write FAILED: <原因> (changed=… keys=…)`，原因细分为
  `unknown_key:x` / `invalid_value:x` / `syntax_check_failed` / `rename_failed`；
- `ctl.sh set` / `save` 记录收到的原始参数（`WEBUI set: …` / `WEBUI save(stdin): …`），
  这样「保存为什么失败」在日志里就有完整证据链。

### 说明

- 配置键与守护逻辑无改动，`config.conf` 兼容 v2.3.2；
- 如果场景页开关仍然回弹：刷 v2.3.3 → 场景页「设置保存诊断」→ **「保存诊断到文件」** →
  把 `/sdcard/Download/cirno-diag-*.txt` 发到反馈邮箱即可。

## v2.3.2 — 场景页保存链路重做

版本号 `v2.3.2` / `versionCode 20302`。

真机反馈：场景页的开关「保存后又自己弹回去」。v2.3.1 修的是**显示**（配置里的引号没剥导致开关显示为关），
这次把**保存链路本身**重做，让它不可能再因为某一环静默失败而回弹。

### 保存链路重做

- **双通道保存**：以前只有一条 `printf … | ctl.sh save`（依赖 stdin + 管道，不同管理器的
  `ksu.exec` 实现细节不完全一致）。现在优先用参数形式 `ctl.sh set 'k=v' …`
  （不依赖 stdin / 管道），失败再自动退回旧的管道方式；哪条通道成功会写进诊断信息；
- **保存串行化**：连点多个开关时排队执行，不会出现「后一次覆盖前一次」的竞态；
- **行内状态**：开关行会显示「保存中 / 已保存 / 失败」，不再只靠一个 3 秒就消失的 toast；
- **失败必回滚 + 说明原因**：两条通道都失败时开关回滚到原值，并弹出具体错误
  （`invalid_value` / `unknown_key` / `write_failed` / errno），绝不假装保存成功；
- **场景页新增「设置保存诊断」折叠面板**：一键把配置文件重新读出，和界面上的开关逐项对比，
  并列出两条通道的命令、errno、stdout、stderr，可一键复制；
- 表单批量提交（数字/文本 + 「保存设置」）也走同一套双通道逻辑。

### 说明

- 这一版没有改配置键、没有改守护逻辑，`config.conf` 与档案完全兼容 v2.3.1；
- 如果刷 v2.3.1 后场景页开关仍会回弹，请刷 v2.3.2，然后打开场景页最下面的
  「设置保存诊断」→「核对配置」，把输出发到反馈邮箱，就能定位是哪一条通道失败。

## v2.3.1 — 开关回弹修复 / 液态底栏 / 守护再降耗

版本号 `v2.3.1` / `versionCode 20301`。

### 修复（真机反馈）

- **切页面回来「启用模块」等开关会变成关闭**。`ctl.sh save` 会把所有值写成单引号
  （`enable='1'`），而 WebUI 的配置解析只对两个名单键剥引号，`num("'1'")` 得到 0，
  于是只要保存过一次（包括开关自动保存），重新渲染表单就显示成关。
  现在解析时统一剥一层引号（单/双引号都认），带引号 / 不带引号的配置都能正确显示。

### 新增：底栏液态玻璃折射

- 外观页新增「液态玻璃折射」开关（`theme.conf` 的 `liquid=1`，默认开）：滑块用
  `backdrop-filter: blur() url(<data:image/svg+xml 位移滤镜>) saturate() brightness()`
  对底下的内容做真实折射 + 轻微色散；
- 滤镜数学移植自 MIT 开源项目
  [nikdelvin/liquid-glass](https://github.com/nikdelvin/liquid-glass)，只搬了
  `getDisplacementMap` / `getDisplacementFilter` 两个纯函数，上游的 Astro / Tailwind /
  anime.js 一个都没引入；按 MIT 要求随模块包分发 `THIRD-PARTY-NOTICES.md`；
- 上游是给大卡片用的，这里按滑块高度重算 depth / strength / 色散；
  `backdrop-filter: url()` 不被支持时自动降级成原来的高光药丸（外观页标签显示「不支持」），
  性能模式下一律禁用（JS 清空 filter 并移除 `liquid-on` 类）；
- `ctl.sh ui get` 的默认值与 `ui set` 的白名单都加上了 `liquid`。

### 守护进一步降功耗 / 占用

- 进程降到 **nice 19** + **IO idle 类**，不再和前台抢 CPU / IO；
- 空闲分级放宽：探测周期 20s → 40s → 60s，心跳 45s → 90s
  （上限仍是 `heartbeat_timeout / 2`，watchdog 照常能判掉线）；
- `state/cpp.stats` 改为隔一次心跳才写，写盘约 60 次/小时（旧版光心跳就 720 次/小时）；
- 回收前先读 `state/last_run`，`cooldown_sec` 冷却期内不 fork（旧版是 fork 进去再被脚本拒绝）；
- 原生组件改用 `-Oz` + `--gc-sections` + 去掉 unwind 表，`cirno_daemon` 220 KB → 209 KB。

空闲时预期：唤醒约 1.7 次/分（v2.2.2 是 60 次/分，另外每 15/45 秒还要 fork 一个 shell），
一小时内守护自身的 CPU 时间应是几百毫秒级 —— 用 `state/cpp.stats` 的 `wakeups` / `cpu_ms`
或 `ctl.sh status --json` 核对。

### 工程

- 新增 `tools/verify.py`：一条命令跑完编码 / 换行、shell lint、JS 语法、配置键一致性、
  打包白名单、ELF 架构、版本号、zip 内容检查（CI 已接入）；
- 新增 `THIRD-PARTY-NOTICES.md` 并加入模块包白名单（MIT 声明必须随二进制一起分发）；
- `src/build.sh` 与本次发布使用同一套 `-Oz` 参数，二进制可逐字节复现。

## v2.3.0 — 双平台适配 + 低功耗守护

版本号 `v2.3.0` / `versionCode 20300`。

### 修复：C++ 守护功耗偏高（根因 + 措施）

v2.2.2 的 `daemon_engine=cpp` 在真机上耗电偏高。把 `src/cirno_daemon.cpp` 逐段过了一遍，
根因有 5 条，本版全部修掉：

1. 主循环 `nanosleep(1s)` **死轮询**：每分钟 60 次唤醒，每次 stat 2 个文件，且每 5 秒写一次心跳；
2. **无条件 fork 子进程**：每 `interval`（15s）跑一次 `reclaim.sh --run`、每 45s 跑一次
   `app_relief.sh`、每 90s 跑一次 `--high-check`，内存完全健康时也照跑；
3. `boot_delay` 被解析但**从未使用**：开机最忙的时候立刻跑全量回收；
4. `app_relief.sh` 没有内存压力门控：内存充裕时也把前台应用换出到 zram，
   前台回读缺页 → CPU 尖峰 + 掉帧 + 耗电；
5. 每次 fork 都写 1 行日志，**日志写放大**。

对应措施（C++ 守护重写）：

- **事件驱动睡眠**：以「心跳 / 内存压力探测 / 日志轮转」三类事件决定唤醒点，
  `nanosleep` 睡到最近的那个事件，不再每秒轮询；被信号打断按 `EINTR` 处理。
  回收 / 大进程看门狗 / 前台舒缓的计时器是纯比较，在这些唤醒点顺便判断是否到点，
  不额外唤醒；
- **内存压力门控**：每次决定 spawn 之前自己读 `/proc/meminfo` 与 `/proc/pressure/memory`，
  用和 shell 完全一致的阈值判断「是否紧张」：
  `low = max(mem_low_mb, MemTotal * mem_low_pct / 100)`，
  `tight = 可用 < low，或 psi_enable 且 PSI some avg10 超过阈值`。
  - `reclaim`：只有 `tight` 才跑，不紧张就跳过，下个周期再看；还会先看
    `state/last_run`，`cooldown_sec` 冷却期内不 fork（旧版是 fork 进去再被脚本拒绝，纯浪费）；
  - `relief`：`relief_gate=1`（默认）时只有 `tight` 才跑；`relief_gate=0` 才按周期跑；
  - `--high-check`：不紧张时按 `high_pss_interval` 跑，紧张时交给 reclaim；
  - 读 meminfo 失败按「紧张」处理，宁可多跑一次也不失灵；
- **自适应空转**：连续多次探测（实现里为 10 次）都不紧张后，探测周期逐步放宽，
  最多到 60 秒；一旦紧张立即恢复 `interval`；
- **`boot_delay` 真正生效**：按系统 uptime 判断——开机后 uptime 未到 `boot_delay`
  就不 spawn 任何子进程（心跳照常写）；被 watchdog 重新拉起时 uptime 早就超过，
  不会重复等一遍。`service.sh` 启动守护前本身也会等满 `boot_delay`，两处不会叠加；
- **心跳 5s → 45s 且可配**：新增 `heartbeat_sec`（默认 45，实际夹在
  `10..min(120, heartbeat_timeout/2)`；把 `heartbeat_timeout` 调小会同时压低上限）；
- **删除每次 spawn/exit 的日志**：只保留 start / exit / 超时 / 错误 / 配置重载 /
  门控状态变化（紧张↔不紧张各记一次），消除写放大；
- `--status` 新增 `profile`、`tight`、`avail`、`psi`、`wakeups`、`probes`、
  `cpu_ms`、`uptime` 字段：`wakeups` / `probes` 是累计唤醒与压力探测次数，
  `cpu_ms` 是守护自身累计 CPU 时间（`getrusage`），可以直接验证功耗修复是否生效；
  同样的统计也写入 `state/cpp.stats`（与心跳同一次唤醒写出）；
- 保留原有的单实例锁 + cmdline 校验、子进程硬超时（reclaim 180s / relief 120s）、
  `SIGHUP` 重载、配置 mtime 变化重载、`oom_score_adj=-900`、日志轮转。

### 合并 ColorOS 17 适配版（yishisanren，基于 v2.0.0）的改进

1. **`reclaim_order=pageout_first`（默认）**：先把冻结应用压进 zram（含 ART 堆），
   还不够才结束进程；`kill_first` 保留原来的「先杀」顺序；
2. **前台舒缓压力门控**：新增 `relief_gate`（默认 1），只有内存紧张 / PSI 超标才自动舒缓；
   `ctl.sh apprelief --force` 不受此限制；
3. **双 cgroup 布局**：同时认 `apps/uid_*/pid_*` 与 `uid_*/pid_*` 两种目录，
   并用 `cgroup.events` 判断「实际冻结」（含 uid 层冻结）；
4. **冻结态直接 SIGKILL**：不再解冻→等 1 秒→杀，只在杀不死时回退解冻重试，
   避免应用在这一秒里又跑起来、与 Cirno 状态不一致；
5. **OEM 自管 zram 不重建**：HyperOS / ColorOS 的「内存扩展」由系统管理；
   `zram_enable=1` 且 `zram_disksize_mb=0`（自动）时直接跳过，不 reset / 不 mkswap，
   只有用户显式设置 `zram_disksize_mb>0` 才允许接管；
6. **包名保护扩展**：ColorOS / OPPO / realme 的 `com.oplus.*`、`com.coloros.*`、`com.heytap.*`、
   `com.oppo.*`、`com.nearme.*`、`com.finshell.*` 与 HyperOS 的 `com.miui.*`、`com.xiaomi.*`、
   `com.mi.*` 按档案进入默认排除名单；
7. **`cirno_pageout` 计量修正**：按常驻匿名页分配预算、按 `VmSwap` 实际增量报告，
   新增 `--include-art`（由调用方决定是否把 ART 堆纳入换出范围）；
8. **`deep_pageout` 复用候选表**，不再每次全量扫 `/proc`；
9. **`ctl.sh diag` 增强**：device / soc、oplusrom、ColorOS 判定、root 方案、
   cgroup 布局与冻结计数、前台包、zram 详情、vm 参数、memcg、psi、props 过滤、
   候选扫描前 15 行；
10. **首刷默认 `dry_run=1`**（演练），WebUI 里可关。

### 新增：安装时用音量键选择系统

- 刷入时打印菜单，`getevent` 读音量键，**8 秒**超时：
  - **音量上** → HyperOS / MIUI；
  - **音量下** → ColorOS / realmeUI / OxygenOS；
  - 不按 / 读不到输入设备 → 自动检测；
- 自动检测顺序：`ro.mi.os.version.name` 或 `ro.miui.ui.version.name` → HyperOS；
  `ro.build.version.oplusrom` / `ro.build.version.opporom` 或存在 `/my_product` → ColorOS；
  否则 `generic`；
- 选择结果写入 `profile.pending`，首次开机由 `post-fs-data.sh` 的 `profile_bootstrap` 套用：
  - 全新安装且未按键：`auto`，按检测结果套用对应档案；
  - **升级安装**且未按键：`keep`，只更新 `device_profile`，**不覆盖**已有参数；
  - 环境变量 `CR_PROFILE=hyperos|coloros|generic|auto` 优先级最高，方便脚本化刷入；
  - 应用完成后删除 `profile.pending` 并写 `state/profile.applied=<名字>`。

### 新增配置键

| 键 | 取值 | 默认 | 说明 |
|---|---|---|---|
| `device_profile` | `auto` / `hyperos` / `coloros` / `generic` | `generic` | 系统适配档案；`auto` 只出现在安装标记里，运行时一定是具体值 |
| `reclaim_order` | `pageout_first` / `kill_first` | `pageout_first` | 回收顺序：先页换出还是先结束进程 |
| `relief_gate` | `0` / `1` | `1` | 1 = 前台舒缓只在内存紧张 / PSI 超标时自动执行 |
| `heartbeat_sec` | 数字 | `45` | C++ 守护写心跳的间隔（秒），clamp 10..120 |

### 默认值变更

| 键 | v2.2.2 | v2.3.0 | 原因 |
|---|---:|---:|---|
| `interval` | 15 | **20** | 降低守护唤醒频率 |
| `deep_pageout_max_mb` | 96 | **192** | 一次深回收更彻底 |
| `app_reclaim_interval` | 45 | **60** | 前台舒缓少跑几次 |
| `zram_enable` | 1 | **0** | OEM 自管 zram，默认不接管 |
| `dry_run` | 0 | **1** | 首刷演练 |

`vm_tune` 的全局默认保持 1：它只写 sysctl，`zram_enable=0` 时不会碰 zram 设备
（`coloros` 档案会把它设为 0，完全不修改系统内存参数）。

### 新增文件与命令

- `profiles/hyperos.conf`、`profiles/coloros.conf`：只写需要覆盖的键（`k=v`，一行一个）；
  `generic` 不建档案文件，表示不覆盖任何值；
- `sh bin/ctl.sh profile` / `profile --json` / `profile list` / `profile detect` /
  `profile apply <名字>`；
- `sh bin/ctl.sh snapshot` 的 `status` 新增 `device_profile` / `detected` / `rom` / `order` /
  `relief_gate` / `total_paged` / `last_paged` / `tight` / `wakeups` / `cpu_ms`；
  `info` 段也有 `rom` / `device_profile` / `tight` / `wakeups` / `cpu_ms`；
- WebUI：「场景」页新增「系统适配」卡片（HyperOS / ColorOS / 通用，含「检测到：<rom>」），
  「控制台」页补守护引擎、档案、回收顺序、门控信息。

### 真机反馈修复与体验

> 这一节的内容已挪到上面的 **v2.3.1**：开关回弹修复、液态玻璃折射、守护再降功耗与占用。

### 已知限制

- **仍未在全部机型验证**：本版**没有真机功耗实测数据**，省电幅度需要在你的设备上
  用 `cirno_daemon --status` 的 `wakeups` 与日志频率自行观察；
- 功耗修复针对的是 C++ 守护；`daemon_engine=shell` 仍是原来的调度方式；
- 档案只覆盖档案文件里列出的键；`keep` 的升级安装不会帮你改已有参数，
  想换成另一套档案请手动 `ctl.sh profile apply`；
- 不同 ROM 的 cgroup 布局、zram 实现、`dumpsys` 输出格式仍可能不同，
  遇到识别错误请把 `ctl.sh diag` 的结果发到反馈邮箱。

### 致谢

ColorOS 17 适配版 `v2.0.0-coloros.1` 的作者 **yishisanren**（基于 flyingr 的 v2.0.0）。
本版合并了其中经过验证的改进：先压缩后结束、双 cgroup 布局与 `cgroup.events` 判冻结、
冻结态直接 SIGKILL、OEM zram 保护、`cirno_pageout` 计量修正、增强诊断等。
原作者 **flyingr** 的署名与版权保留。

## v2.2.2 — 开关点不动 / 保存语义

### 修复

- **开关点不动**：`style.css` 里色块和开关都用了 `.sw`，后面的色块规则
  （34×34、3px 边框、圆角 50%）把开关的尺寸和边框覆盖了，点击热区被破坏。
  现在色块规则限定为 `.swatches .sw`。
- **开关改动立即保存**：以前改完还要再点「保存设置」，容易误以为没生效。
  现在拨动开关会直接写入配置，成功/失败都有 toast，失败会自动弹回原状态。
- 「常用设置」上方加了一行提示：开关立即保存，数字/文本仍需点保存。

### 说明

`enable=0` **只停回收和 VM 调参，不会停止守护进程**，所以状态栏仍显示「运行中」是正常的；
想彻底停下用 `ctl.sh stop`。

---

## v2.2.1 — 主线程阻塞与玻璃质感

### 卡顿（主线程）

你的判断是对的：`ksu.exec` 是**同步**接口，每次调用都会占住 WebView 的 JS 主线程，
旧版一次刷新要分别跑 `status`、`info`、`log` 三个命令，叠在一起就是明显的掉帧。

- 新增 `ctl.sh snapshot`：**一次调用同时返回状态和设备信息**，WebUI 每次刷新只发一个 exec；
- 轮询改成 `setTimeout` 链（上一次跑完才排下一次），不再用 `setInterval` 叠加；
- 状态 30 秒、日志 90 秒；**触摸/滚动后 3.5 秒内暂停轮询**，避免“点了没反应”；
- 首屏延后 60ms 再发 exec，先让浏览器把界面画出来；
- 状态内容没变化时直接跳过 `renderStatus`，不碰 DOM；
- 卡片阴影从 24px 模糊降到 14px，减少每帧的重绘面积。

### 液态玻璃底栏

之前只是「半透明 + 一条渐变」，因为 Android WebView 对 `backdrop-filter` 支持很差
（很多机型直接忽略，或者每帧重算导致卡顿）。这一版**完全不依赖 backdrop-filter**，
改用分层合成：

- 底部半透明基底 + 顶部镜面高光 + 底部反射；
- 一层**缓慢横向流动的折射光斑**（纯 transform 动画，GPU 友好）；
- 选中项是带内高光和投影的“药丸”，弹性滑动；
- 深色模式单独一套玻璃配色；
- 性能模式下自动关掉流动光斑与所有过渡。

---

## v2.2.0 — WebUI 性能与液态玻璃底栏

### 性能（解决卡顿）

- **卡片不再使用 `backdrop-filter`**：旧版每张卡片都在做实时模糊，滚动时 GPU 压力很大；
  现在只有底栏保留模糊。
- 状态轮询 10s → **20s**，日志轮询 20s → **60s**，且内容没变时不重写 DOM。
- `ksu.exec` 是同步调用，加了 `statusBusy` 互斥，避免轮询叠加把 UI 线程堵住。
- 日志默认只取 120 行；滚动容器加 `contain: content`。
- 去掉 `background-attachment: fixed`（WebView 滚动时非常耗性能）。
- 新增**性能模式**开关：关闭模糊、过渡动画和高光，低端机可一键变流畅。

### 液态玻璃底栏

- 新的浮动胶囊底栏：毛玻璃、双层高光、内阴影，模拟 iOS 的液态玻璃质感。
- 跟随当前页滑动的**高光药丸**（`cubic-bezier(.22,1.2,.36,1)` 弹性过渡）。
- 两种样式：**液态玻璃**（浮动胶囊）/ **简洁长条**（通栏），可在外观页切换。

### 更多外观自定义

- 圆角 8–36px 可调；
- 组件透明度 30%–100%；
- 背景遮罩 0–90%（用图片背景时控制文字可读性）；
- 主题（跟随系统 / 浅色 / 深色）、四种强调色、纯色或图片背景；
- 全部外观保存在 `/data/adb/cirno_reclaim/webui/theme.conf`。

### 其它

- `ctl.sh ui set` 增加 `radius` / `dim` / `nav` / `perf` 校验。

---

## v2.1.3 — 彻底去掉 mksh 解析地雷

v2.1.2 只是把方括号里的 `;` 拆开，但 `${var%%;*}` 这类**参数展开里的分号**同样会让 mksh 解析失败，
所以函数仍然没被定义。这一版把所有可疑写法都换掉了：

- `in_list()`：改用 `IFS=';'` + `set -f` 切分，不再用 `${var%%;*}` / `*';'*`；
- 字符串键校验：改用 `grep` 检查字符集，`case` 里不再出现包含 `;` 的方括号；
- 去首尾空白：改用纯空格循环，不再用 `[![:space:]]`；
- 行内注释：改用字面量 `' #'` 模式，不再用 `[[:space:]]`；
- `ctl.sh` 启动时先 `sh -n common.sh` 预检，语法错误直接打印行号并退出，
  不会再出现「cfg_load: command not found」这类连锁报错。

> 如果你还想先验证再重启，刷入后执行：
> `su -c 'sh -n /data/adb/modules/cirno_reclaim/bin/common.sh && echo SYNTAX-OK'`
> 打印 `SYNTAX-OK` 再重启。

---

## v2.1.2 — 修复 mksh 语法错误（关键）

- **根因**：`common.sh` 的字符集校验写成 `*[!A-Za-z0-9_.:;*/+=, -]*`，
  mksh 会把方括号里的 `;` 当成命令分隔符，直接报
  `syntax error near unexpected token ';'`，导致 `common.sh` 后半段函数全部没有定义。
  于是：配置读不到、日志不写、守护起不来、预设保存报 `unknown-key`——全是这一个错误引起的。
- 改为**先按 `;` 切段、再逐段校验字符集**，方括号里不再出现 `;`。
- `tools/lint_sh.py` 增加规则：方括号模式里出现 `;` 直接判 error，防止回归。
- `ctl.sh` 的 `bgurl` 校验改用 `grep`，避开同类 mksh 解析问题。

---

## v2.1.1 — 修复刷入后的实际问题

### 修复

- **配置读不到**：`ctl.sh config` 在配置缺失/为空时先复制模块默认值，仍失败就直接生成一份完整默认配置；
  WebUI 增加「直接 `cat` 配置文件」的二次兜底，并在失败时显示两个命令的原始错误。
- **日志一直是 `no log yet`**：`post-fs-data.sh` 与 `service.sh` 写入启动时间戳；
  `ctl.sh log` 与 `doctor` 会显示这两个时间戳，用于区分「模块脚本没跑」和「日志文件没写」。
- **状态栏不沉浸**：切换主题时同步更新 `theme-color` 与 `color-scheme`，并在首屏前用内联脚本应用已保存主题；
  顶栏加上 `safe-area-inset-top` 内边距。
- **透明度/背景无效**：确认 `--alpha` 作用到卡片、导航、Toast 等所有组件；
  选择「图片」但没有图片时给出提示而不是静默无变化；切换主题会立即更新状态栏颜色。
- 避免在 `file://` 页面用 `?v=` 查询串（部分 WebView 会因此 404），改为普通引用。

---

## v2.1.0 — C++ 守护 + 新 WebUI

### 新增

- **C++ 守护进程** `bin/cirno_daemon`（`src/cirno_daemon.cpp`）：
  - 单调时钟调度，不受系统时间跳变影响；
  - 每 5 秒写心跳，配置文件变更自动重读（也可 `SIGHUP`）；
  - 子进程硬超时（回收 180s / 舒缓 120s），`dumpsys` 卡住时 SIGKILL，不会拖死守护；
  - `mkdir` 原子锁 + pid 命令行校验，避免双实例；
  - 支持 `--status` / `--check` / `--once` / `--foreground`，方便脚本与排障；
  - 配置 `daemon_engine=shell` 可回退到原 shell 守护；二进制缺失时自动回退。
- **WebUI 重做**（对齐 HyperOS 控制台风格）：
  - 四页：控制台 / 场景 / 外观 / 关于；
  - 控制台：圆环仪表、可用内存、累计回收/释放、守护引擎、页换出状态、四个动作按钮、设备信息、日志、自检；
  - 场景：三个预设 + 12 项常用设置 + 高级参数折叠；
  - 外观：跟随系统/浅色/深色、四种强调色、纯色/图片背景（链接或本地图片）、组件透明度；
  - 关于：版本、作者、反馈邮箱、一键复制诊断、写邮件。
- **`ctl.sh` 新命令**：`doctor`（自检）、`info`（设备/引擎 JSON）、`ui get|set`（外观配置）、
  `engine`；`log` 现在带文件路径、大小、行数与轮转提示；`config` 缺失时自动从模块默认值恢复。
- **主题持久化**：外观写到 `/data/adb/cirno_reclaim/webui/theme.conf`，本地背景图存 WebView。
- **C++ 守护与 pageout helper 均由 zig 交叉编译**，静态、无解释器，随包内置。

### 修复

- **配置无法读取**：WebUI 全部命令改用 `/system/bin/sh` 绝对路径；`ctl.sh config` 自动修复缺失配置
  并在输出里带上路径/大小；读取失败时禁用保存并显示原始 `errno/stderr`，不再静默。
- **日志无法显示**：`ctl.sh log` 直接读模块日志文件并返回路径、大小、行数与最近 N 行；
  WebUI 日志区每 20 秒自动刷新，支持手动刷新；日志不存在时给出明确原因。
- **刷入包夹带无关文件**：模块 zip 改为运行期白名单，只保留脚本、`bin/`、`webroot/`、
  `config.conf`、`LICENSE` 与两个原生组件源码；文档/构建脚本/发布说明只进源码包。
- **配置读取死循环风险**：`cfg_load` 先补齐文件末尾换行，再逐行 `read`，避免无换行时
  在 EOF 反复处理同一行。
- **PATH 不完整**：脚本入口先补 `PATH=/system/bin:...`，避免 WebUI 环境下 `awk/tail/dirname` 找不到。

### 变更

- 版本号 `v2.1.2` / `versionCode 20100`。
- 默认守护引擎为 `cpp`。
- `service.sh --resume` 只做 `vm_tune reassert`，不会重建 zram/swapfile。
- `enable=0` 时连 VM 调参也停止（之前只停回收）。

### 已知限制

- **未在真机完整验证**；首刷建议 `dry_run=1`、`zram_enable=0` 观察一轮。
- C++ 守护只负责调度与超时，实际回收仍由 shell 引擎执行，所以回收逻辑的问题仍以日志为准。
- 本地背景图只保存在 WebView，换设备/清数据会丢失；图片链接会写入设备。

---

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
- **预设**：`conservative` / `balanced` / `aggressive`。
- **KernelSU 支持**：`customize.sh` 识别 KSU / Magisk / APatch，带 `action.sh` 与 `webroot/`。
- **zram / swapfile / VM 调参**：吸收 HybridRAM 思路；`vm_reassert` 定时回写被 Android 重置的参数。
- **原生 helper**：`src/cirno_pageout.c` + zig 交叉编译。
- **工程规范文件**：`.editorconfig`、`.gitattributes`、`CODE_OF_CONDUCT.md`、Issue 表单、
  PR 模板、`docs/SECURITY-AUDIT.md`、`tools/checksums.py`。

### 安全

- **配置文件不再被 `source`**：逐行解析 + 键白名单 + 类型校验 + `case` 直接赋值，
  `;`/空格/`$(...)`/`#` 都不再可能变成命令。
- `ctl.sh save` / `set` 复用同一套校验，所有值单引号写入，`zram_algorithm` 精确枚举。
- `interval` / `watchdog_interval` / `heartbeat_timeout` 增加下限与联动（`cfg_clamp`）。
- pid 文件与锁加入命令行核对；单实例锁改为 `mkdir` 原子锁。
- `kill` 在解冻后重新校验 starttime / oom / 前台 / 保护名单，不满足就冻回去。
- zram 重建增加 `/proc/swaps` basename 匹配、`swapoff` 失败即中止；swapfile 增加空间检查。
- WebUI 配置读取失败时禁用保存，缺失布尔键不再写成 0。

### 变更

- 默认值更积极：`max_kills_per_run` 3→4、`max_kills_per_hour` 12→20、`min_frozen_min` 10→5、
  `min_process_mb` 64→48、`interval` 30→15、`app_pageout_max_mb` 128→192。
- 日志统一到模块目录 `log/reclaim.log`，按 `log_max_kb` 轮转。
- 模块 id 保持 `cirno_reclaim`，可从 cirno-reclaim 直接升级。

### 修复

- 修复前台只 trim 主进程、效果有限的问题。
- 修复回收循环过早退出、单次回收数量过少的问题。
- 修复守护进程被杀后无人拉起的问题。
- 修复升级安装时旧守护仍在运行的问题。
