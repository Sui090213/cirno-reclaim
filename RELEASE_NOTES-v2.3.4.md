# Cirno Reclaim Hybrid v2.3.4

**Cirno 冻结器的配套内存回收模块** · Magisk / KernelSU / APatch · Android 12+

本版两个重点：**修复 C++ 守护的耗电问题**，以及**同时适配 HyperOS 与 ColorOS**
（安装时用音量键选，或自动识别）。

作者：flyingr · ColorOS 17 适配致谢：yishisanren · 反馈：asui20090213@outlook.com

---

## v2.3.4：真机诊断定位到的两个 bug

根据你发来的诊断文件（KernelSU + Android 15，Xiaomi 2211133C）定位到：

**① 你的设备上原生组件其实一直没装上（严重）**

诊断里 `pageout: helper missing` / `cpp daemon: binary missing (engine = shell)` ——
安装脚本把 `arm64-v8a` 当成「非 arm64」，把 `cirno_daemon` 和 `cirno_pageout` 删掉了。
所以之前几版在 KernelSU 上跑的都是 shell 守护、页换出完全没用上。本版已修（前缀匹配架构）。

**② 「开关回弹」不是保存失败，是读取失败**

诊断显示每次保存都成功（`config write: ok`、`errno=0`、`stdout={"ok":1}`），
但 WebUI 侧 `界面缓存: {}` —— 前端把配置读成了空，所有开关按「关」渲染；
你再打开、切页面回来又按空配置渲染成关，看起来就像回弹。
本版新增 `ctl.sh configjson`（单行 JSON，直接给前端 `JSON.parse`），
不再让 WebView 去解析带注释/单引号的多行配置文本；
同时「保存设置」只提交你真正改过的字段（顺手修掉了会清空 `exclude_packages` 的坑）。

刷完请再发一次「保存诊断到文件」：`--- config raw ---` 和 `--- configjson ---`
这两段会直接告诉我们前端到底读到了什么。

---

## v2.3.3：诊断不用剪贴板也能带出来

真机上「复制诊断」也会失败 —— WebView 的剪贴板 API 经常不可用（非安全上下文、没权限、
`execCommand('copy')` 被拒）。这一版把「把信息拿出来」这件事改成不依赖剪贴板：

- 场景页「设置保存诊断」新增 **「保存诊断到文件」**：把模块侧诊断 + WebUI 侧诊断
  （保存通道、命令、errno、stdout/stderr、界面缓存）写进
  `/sdcard/Download/cirno-diag-<时间>.txt`（写不进去会自动换 `/sdcard/`、`/data/local/tmp/`）；
- 「复制诊断」失败时也会自动落盘并提示路径，两个按钮都可用；
- 诊断里补了最关键的几行：配置文件大小 / 可写 / 可读 / `sh -n` 结果、data 目录可写性，
  以及最近 12 条 `config write` / `WEBUI save` 日志 —— 保存到底为什么失败会直接写在里面；
- 诊断区域现在支持长按手动选择复制。

**如果你遇到场景页开关回弹**：刷完 → 场景页最下面「设置保存诊断」→「保存诊断到文件」→
把 `/sdcard/Download/cirno-diag-*.txt` 发到 asui20090213@outlook.com。

---

## 如果你装了 v2.3.1 或更早

直接覆盖刷入即可（`/data/adb/cirno_reclaim/config.conf` 与外观配置都会保留）。

**v2.3.4 修的是场景页开关「保存后自己弹回去」**。v2.3.1 只修了显示（配置里的引号没剥），
这次把保存链路重做了：

- **两条保存通道**：优先 `ctl.sh set 'k=v'`（参数形式，不依赖 stdin / 管道），
  失败自动退回原来的 `printf … | ctl.sh save`。以前只有后一条，某些管理器/WebView 下
  管道或 stdin 不按预期工作就会静默失败，开关看起来就像自己弹回去了；
- 开关行内会显示「保存中 / 已保存 / 失败」，失败会回滚并弹出具体原因，不再假装成功；
- 连点多个开关会排队保存，不会互相覆盖；
- 场景页最下面新增 **「设置保存诊断」**：一键把配置文件重新读出、和界面开关逐项对比，
  并列两条通道的命令与返回。如果还回弹，点「核对配置」→「复制诊断」发我即可。

如果你装的是 v2.3.1，下面这些增量也一起包含：

- **修复：切页面回来「启用模块」等开关显示成关闭**。原因是 `ctl.sh` 保存配置时会把值写成
  单引号（`enable='1'`），而 WebUI 解析时只有两个名单键会剥引号，`'1'` 被当成非数字 0。
  现在统一剥引号，保存过的配置也能正确显示（守护其实一直在正常跑，只是显示错了）。
- **底栏换成真正的液态玻璃折射**：外观页新增「液态玻璃折射」开关，默认开。
  滑块用 `backdrop-filter: url(<SVG 位移滤镜>)` 真实折射底下的内容（滤镜移植自 MIT 开源的
  [nikdelvin/liquid-glass](https://github.com/nikdelvin/liquid-glass)，声明见
  `THIRD-PARTY-NOTICES.md`）。你的 WebView 不支持这个特性时外观页会显示「不支持」，
  自动退回原来的高光药丸；性能模式下一律禁用；卡顿就一键关掉。
- **守护再省一点**：进程 nice 19 + IO idle；空闲时探测放宽到 60 秒、心跳放宽到 90 秒、
  统计文件隔次写；冷却期内不再 fork 空跑的回收；二进制约 209 KB。
  空闲唤醒约 1.7 次/分（v2.2.2 是 60 次/分），可用 `state/cpp.stats` 的
  `wakeups` / `cpu_ms` 自行核对。
- 新增 `tools/verify.py`（一条命令跑完发布前静态检查）与 `THIRD-PARTY-NOTICES.md`。

---

## 这一版做了什么

**① 守护更省电（重点修复）**

v2.2.2 的 C++ 守护被指出耗电偏高，根因已定位并全部修掉：

- 不再每秒轮询：只在「心跳 / 内存压力探测 / 日志轮转」这几个事件点醒，
  回收 / 大进程检查 / 前台舒缓的计时器顺手比较，不额外唤醒；
- 不再无条件跑回收：只有内存真的紧张（可用内存低于阈值 / PSI 超标）才启动回收脚本；
  连续多次不紧张后探测周期还会自动放宽（最多 60 秒）；
- `boot_delay` 真正生效：按系统 uptime 判断，开机最忙的那段时间不跑回收
  （被 watchdog 拉起时 uptime 早已超过，不会重复等）；
- 心跳从每 5 秒一次改为 45 秒一次（`heartbeat_sec` 可配）；
- 不再每次启动子进程都写一行日志；
- 前台舒缓只在内存紧张时自动执行（`relief_gate=1`），不再在内存充裕时换出你正在用的应用。

**② 吸收 ColorOS 17 适配版（yishisanren，基于 flyingr v2.0.0）**

- 默认**先压缩、不够再结束**：`reclaim_order=pageout_first`，把冻结应用（含 ART 堆）
  压进 zram 就够了的话，一个都不杀；
- 双 cgroup 布局都认（`apps/uid_*/pid_*` 与 `uid_*/pid_*`），用 `cgroup.events` 判断实际冻结；
- 冻结态直接 `SIGKILL`，不再先解冻等 1 秒；
- HyperOS / ColorOS 的 OEM zram（「内存扩展」）**不重建、不改大小**；
- 默认排除名单补充 ColorOS / HyperOS 系统应用前缀；
- `cirno_pageout` 修正：按常驻匿名页算预算、按 `VmSwap` 实际增量报告，新增 `--include-art`；
- `ctl.sh diag` 诊断信息更全，反馈时一次复制就够。

**③ 安装时用音量键选系统**

刷入时 8 秒内：

| 按键 | 选择 |
|---|---|
| **音量上** | HyperOS / MIUI |
| **音量下** | ColorOS / realmeUI / OxygenOS |
| **不按** | 自动检测 |

首次开机自动套用对应档案。**升级安装不按键 = 保留你现有的全部参数**，
只把 `device_profile` 更新为检测结果。

**④ 新增配置键与默认值调整**

新增 `device_profile`、`reclaim_order`、`relief_gate`、`heartbeat_sec`。
默认值变化：`interval` 15→20、`deep_pageout_max_mb` 96→192、
`app_reclaim_interval` 45→60、`zram_enable` 1→0、`dry_run` 0→1（首刷演练）。

**⑤ WebUI**

- 「场景」页新增「系统适配」卡片：HyperOS / ColorOS / 通用，显示「检测到：<rom>」；
- 「控制台」页补守护引擎、档案、回收顺序、门控信息。

---

## 升级步骤

### 从 v2.2.2 升级（推荐）

1. 下载 `Cirno-Reclaim-Hybrid-v2.3.4.zip`；
2. 在 Magisk / KernelSU / APatch 里直接刷入（**不要**先卸载，覆盖刷入即可）；
3. 刷入过程中注意音量键提示（8 秒）：
   - 想沿用现有参数：**什么都别按**，等它自动检测；
   - 想明确指定平台：音量上 = HyperOS，音量下 = ColorOS；
4. 重启。首次开机自动处理档案，`/data/adb/cirno_reclaim/config.conf` 不会被覆盖；
5. 打开 WebUI，「场景 → 系统适配」确认当前档案。

> 升级用户不会被强制切到演练模式：`dry_run` 保持你原来的值。
> 全新安装的默认 `dry_run=1`，需要你手动关掉才会真正回收。

### 全新安装

1. 刷入 zip，用音量键选平台（或等自动检测）；
2. 重启；
3. 打开 WebUI，先在演练模式（`dry_run=1`）观察一两天，日志里应出现
   `DRY would ...` 而不是真正的 `RECLAIM` / `SIGKILL`；
4. 确认无误后在「场景」页关掉演练模式并保存。

---

## 如何验证升级成功

### 1. 看当前档案

```sh
ctl=/data/adb/modules/cirno_reclaim/bin/ctl.sh

sh $ctl profile
```

应输出三行，例如：

```text
device_profile=hyperos
detected=hyperos
rom=HyperOS 2.0
```

`device_profile` 与 `detected` 一致说明套用正确；`rom` 是你系统的可读名字。

更结构化的版本：

```sh
sh $ctl profile --json
# {"ok":1,"device_profile":"hyperos","detected":"hyperos","rom":"HyperOS 2.0","applied":1}

sh $ctl profile list
# {"ok":1,"list":["hyperos","coloros","generic"],"detected":"hyperos","current":"hyperos"}
```

### 2. 看守护状态、唤醒次数与 CPU 开销

```sh
sh /data/adb/modules/cirno_reclaim/bin/cirno_daemon --status
# 或
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh status --json
# 或
cat /data/adb/cirno_reclaim/state/cpp.stats
```

输出里关注：

- `"engine":"cpp"`：C++ 守护在跑；
- `"profile":"hyperos"`：档案已生效；
- `"interval":20`：探测周期；
- `"tight":0`：当前不紧张（不紧张时不该频繁回收）；
- `"wakeups":N`：累计唤醒次数。**放一段时间再看，这个数字应该增长得很慢**；
  旧版空闲时约 60 次/分钟，新版空闲时约 1.5~3 次/分钟；
- `"probes":N`：内存压力探测次数；
- `"cpu_ms":N`：守护自身累计 CPU 时间（utime+stime），**验证省电最硬的指标**。
  正常待机一小时应该只有几百毫秒；
- `"uptime":N`：守护已运行秒数。

日志里 `cpp-daemon: pressure TIGHT` / `relaxed` 的切换频率也能反映门控是否稳定。

### 3. 看日志

```sh
sh $ctl log 120
# 或者
tail -n 120 /data/adb/modules/cirno_reclaim/log/reclaim.log
```

需要认识的几行：

```text
RECLAIM start reason=low avail=812MB target=1200MB order=pageout_first dry_run=0
RECLAIM pid=12345 pkg=com.example.app pss=210MB age=420s freed=180MB avail=1310MB mode=pid
DEEP pid=23456 pkg=com.example.game pss=820MB pageout=192MB
APP RELIEF done pkg=com.example.app pss=1120MB->860MB avail=900MB->1150MB pageout=176MB
```

（第一行 = 内存紧张开始回收；第二行 = 结束了一个进程；`DEEP` = 先压缩了冻结应用；
`APP RELIEF` = 前台舒缓完成。实际输出里的包名 / 数值以你的设备为准。）
另外，`APP RELIEF skip: memory healthy (relief_gate)` 表示门控生效、内存充足所以没做舒缓。

要点：

- 内存充足时**不应该**频繁出现 `RECLAIM start`；出现得少说明门控在工作；
- 日志里不再有每次 spawn/exit 的刷屏记录，这是正常的（写放大已去掉）；
- 演练模式下出现的是 `DRY would ...`，不会真的杀进程。

### 4. WebUI

- 「场景 → 系统适配」：当前档案高亮，顶部显示「检测到：<rom>」；
- 「控制台」：守护引擎、档案、回收顺序（页换出优先 / 先杀）、门控状态；
- 「关于」：版本号应为 `2.3.0`。

---

## 回滚到 v2.2.2

如果新版在你的机型上出现问题（耗电没改善、误杀、卡顿等），可以直接刷回 v2.2.2：

1. 下载 `Cirno-Reclaim-Hybrid-v2.2.2.zip`；
2. 在管理器里直接覆盖刷入（**不需要**先卸载）；
3. 重启即可。

关于配置：

- `/data/adb/cirno_reclaim/config.conf` **不会被删除**，你的回收参数会保留；
- v2.2.2 不认识 v2.3.0/v2.3.4 新增的键（`device_profile` / `reclaim_order` / `relief_gate` /
  `heartbeat_sec`），会忽略它们并在日志里记
  `WARN config: ... invalid line(s) ignored`，这**不是**错误，不影响使用；
- 想回到完全干净的状态：回滚前先备份配置——
  `cp /data/adb/cirno_reclaim/config.conf /data/adb/cirno_reclaim/config.conf.bak`——
  或者回滚后手动删掉上面 4 个新键；
- 如果之前手动 `profile apply` 改过参数，回滚不会自动恢复旧值，需要自己改回或恢复备份；
- 想彻底重来：`touch /data/adb/modules/cirno_reclaim/disable` 后重启先停用模块，
  再决定怎么处理。

---

## 已知限制（请务必阅读）

- **仍未在全部机型验证**，本版**没有提供真机功耗实测数据**。
  省电效果请用上面的 `wakeups` / `cpu_ms` 与日志频率自行观察，不同 ROM / 用法差异会很大；
- ColorOS / HyperOS 的 cgroup 布局、zram 实现、`dumpsys` 输出格式可能因版本而异；
- 两套档案的取值是适配经验值，不是大规模实测的最优值；觉得不合适可改配置或换 `generic`；
- 功耗修复只针对 C++ 守护（`daemon_engine=cpp`）；`daemon_engine=shell` 仍是旧调度；
- 前台页换出需要内核支持 `pidfd_open` + `process_madvise`，否则自动降级为纯 trim；
- 需要 Cirno 本体才能真正「冻结」，本模块只负责回收。

---

## 致谢

- 原作者：**flyingr**（本项目的持续维护者）；
- ColorOS 17 适配版 `v2.0.0-coloros.1` 作者：**yishisanren**（基于 flyingr 的 v2.0.0）。
  本版合并了该分支中经过验证的改进，感谢其完整的适配记录；
- 上游 [Cirno](https://github.com/Freezer-Team/Cirno) 与 HybridRAM 的思路来源；
- 所有提交 Issue / 诊断信息帮助定位功耗根因的用户。

---

## 反馈

- 邮箱：**asui20090213@outlook.com**
- 请附：机型、系统版本（HyperOS / ColorOS 具体版本）、Android / 内核版本、root 方案、
  复现步骤、`sh /data/adb/modules/cirno_reclaim/bin/ctl.sh diag` 的输出、相关日志。

完整文档见仓库 `README.md`、`docs/HYPEROS-COLOROS.md`、`SECURITY.md`。
