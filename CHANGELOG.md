# Changelog

本项目由 **cirno-reclaim**（由 Cirno 派生）与 **HybridRAM** 整合而来，作者 flyingr。

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
