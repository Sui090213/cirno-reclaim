# 安全与正确性审计记录

按版本记录审计过程、发现与处理。目的：让使用者知道哪些地方被认真看过，
哪些风险是已知且被接受的。

> 审计环境：Windows 开发机，**无 Android 设备、无 bash/dash**。
> 结论来自静态阅读、自写检查器（`tools/lint_sh.py`）、字节级检查（CRLF/BOM）与打包校验，
> **没有真机运行验证**。首次刷入请按 README 的「安全首刷」流程。

---

## v2.2.2

### 本版改动与安全影响

| 改动 | 安全影响 | 处理 |
|---|---|---|
| 新增 C++ 守护 `cirno_daemon` | 只读配置、只 `fork/exec` 固定路径脚本，不 eval、不拼命令 | 只解析自己需要的数字键；脚本路径硬编码；子进程超时 SIGKILL；`mkdir` 锁 + pid 命令行校验 |
| WebUI 四页 + 外观设置 | 新增 `ui set` 往设备写 `theme.conf` | 键白名单 + 枚举/范围校验 + 原子替换；本地图片只存 WebView |
| `ctl.sh config` 自愈 | 配置缺失时从模块默认值恢复 | 只复制 `$MODDIR/config.conf`，不执行其中内容 |
| `ctl.sh log` 读日志 | 新增日志读取路径 | 只读固定 `$LOG_DIR/reclaim.log`，不接收任意路径 |
| 模块包瘦身 | 减少包体积与攻击面 | 只保留运行期文件 + `LICENSE` + 原生源码 |
| `cfg_load` 末尾换行 | 修复无换行时 EOF 反复处理同一行的死循环风险 | 解析前先补齐换行 |

### 已知未修

- C++ 守护未在真机运行；`--status`、超时、回退逻辑只做了编译与静态检查；
- `app_relief` 仍未对目标 PID 做 `starttime` 复核（只 trim，不杀进程）；
- helper 内部 TOCTOU（先读 smaps 后 `pidfd_open`）仍在；
- 未在 AOSP / HyperOS 真机验证 `dumpsys` 与 `cgroup` 路径。

---

## v2.0.0

### 审计经过

| 轮次 | 方式 | 结果 |
|---|---|---|
| 1 | 作者自查 | 发现并修复 pid 复用、包名未校验、配置字符集等问题 |
| 2 | 独立只读审计（另一起 agent，未改文件） | **推翻第 1 轮的 P0 结论**：`config.conf` 仍在 `source`，字符集放行空格与 `;`，`#` 截断可绕过；另列 13 项 P1、若干 P2 |
| 3 | 修复 | 配置改为「不 source 的解析器」；逐条修 P1；补文档 |

第 1 轮的教训：**「语法检查 + 字符集限制」不等于安全**。只要还 `source`，
`zram_algorithm=lz4 reboot` 就是一条合法赋值加一条命令。这一轮把它彻底改成数据解析。

### P0（已修）

| 编号 | 问题 | 修复 |
|---|---|---|
| P0-1 | `cfg_load()` 直接 `source config.conf`；`cfg_safe()` 允许值含空格/`;`；`${v%%#*}` 截断使 `x#;reboot` 绕过；不校验键白名单（`PATH=`、`LD_PRELOAD=` 可注入）；`ctl.sh` 对非字符串值不加引号、`zram_algorithm` 接受任意值 | 删除 `source`。改为 `cfg_trim` + `cfg_key_allowed` + `cfg_value_type_ok` + `cfg_assign`（`case` 直接赋值，不 eval）；行内注释只认「空白 + `#`」，其它 `#` 判非法；`ctl.sh` 复用同一套类型校验，所有值单引号写入，`zram_algorithm` 精确枚举 |

### P1（已修）

| 编号 | 问题 | 修复 |
|---|---|---|
| P1-1 | `enable=0` 仍会做 VM/zram 调参 | `service.sh` 与 `daemon.sh` 的 VM 分支都加 `enable=1` 判定 |
| P1-2 | `interval` / `watchdog_interval` / `heartbeat_timeout` 无下限，可造忙循环/重启风暴 | `cfg_clamp()` 统一夹区间，并强制 `heartbeat_timeout ≥ 3×interval`；`ctl.sh` 同步做范围校验 |
| P1-3 | `is_running_pidfile` 只看进程活着；`customize.sh` 升级时按 pid 文件直接 `kill -9` | pid 文件检查增加命令行匹配；`customize.sh` 杀之前核对 `/proc/<pid>/cmdline` 含 `cirno_reclaim` |
| P1-4 | 单实例锁是 TOCTOU；reclaim 无锁 | 改为 `mkdir` 原子锁（`lock.daemon` / `lock.watchdog` / `lock.reclaim`），持有者死亡自动清理；reclaim 加锁避免与自动回收并发 |
| P1-5 | kill 前的竞态检查在「解冻 + sleep 1」之前 | 解冻后重新校验 `starttime` / `oom_score_adj` / 保护名单 / 前台，任一不满足就**冻回去**并放弃 |
| P1-6 | `dry_run` 不写 `last_run`、不限量、不 prune，反而最费 CPU | dry-run 也计 `max_kills_per_run`、写 `last_run`（让 cooldown 生效）、执行 `frozen_tsv_prune` |
| P1-7 | 有 cgroup 目录但无冻结进程时回退全量扫 `/proc` | 布局存在就只用 cgroup 枚举，无命中不回退；无布局才 idle 并只记一次日志 |
| P1-8 | `dumpsys activity activities` 每轮/每候选都跑 | 新增 `fg_pkg_cached`（30s 缓存），kill 循环复用；`protect_foreground=0` 时不再调用 |
| P1-9 | zram 判定按完整路径、`swapoff` 失败仍 `mkswap`、disksize 忙时静默失败 | 按 basename 匹配 `/proc/swaps`；`swapoff` 失败且仍在用时拒绝操作；disksize≠0 先 `reset`，仍忙则跳过 |
| P1-10 | swapfile 不检查剩余空间、`swapoff` 失败仍删活动文件 | `df` 检查（留 256MB 余量）；活动 swapfile 只有在 `swapoff` 成功后才重建；分配/mkswap 失败即清理 |
| P1-11 | `service.sh --resume` 会重新 `vm_tune apply`（可能重建 swapfile） | resume 只执行 `vm_tune.sh reassert` |
| P1-12 | WebUI 配置读取失败/缺键时保存会把开关写成 0 | `loadConfig` 校验 `errno` 与 `enable=`；失败则禁用保存；缺失的布尔键不写入；名单允许清空 |
| P1-13 | `in_list` 用无引号 `for` 展开，`*` 会被 cwd 文件名撑开 | 改为逐段 `case` 匹配，不做路径名展开 |

### P2（部分处理）

| 编号 | 状态 | 说明 |
|---|---|---|
| P2-3 `grep -q` 当正则 | 已修 | `proc_cmdline_has` 改用 `grep -qF --` |
| P2-4 `pid_starttime` 解析 | 已修 | `sed 's/^[0-9]* (.*) //'` + 字段数校验 |
| P2-6 `cfg_get` 的 sed 注入面 | 已删 | 该函数未使用，直接移除 |
| P2-7 `screen_on` 失败时按灭屏 | 已修 | 读不到状态时按「亮屏」处理，宁可不回收 |
| P2-10 深回收未过滤 include 名单 | 已修 | `deep_pageout` 增加 `pkg_included` 判定 |
| P2-14 卸载残留 swap | 已修 | `uninstall.sh` 先 `swapoff` 本模块 swapfile 再删除；VM 参数需重启恢复，已在文档写明 |
| P2-16 customize 的 ARCH/权限 | 已修 | `ro.product.cpu.abi` 兜底；`set_perm*` 不存在时退回 `chmod` |
| P2-17 打包/CI | 已修 | 模块 zip 改白名单（只含运行期文件 + LICENSE + helper 源码）；CI 生成并上传 `CHECKSUMS.txt` |
| P2-18 WebUI 轮询 | 已修 | 5s → 15s |
| P2-19 JSON 未转义 | 已修 | `--reason` 限制为 `[A-Za-z0-9_().<>-]`，否则回落 `auto` |
| P2-20 daemon 在 MODDIR 消失时忙循环 | 已修 | 检测到目录不存在时 `sleep 5` 后继续 |
| P2-21 watchdog 删除 `.stop` | 已修 | 重启 daemon 不再动 `.stop` |
| P2-22 boot 属性 | 已修 | 同时看 `sys.boot_completed` 与 `dev.bootcomplete`，超时 10 分钟 |
| P2-23 `action.sh` 的 `$0` 无斜杠 | 已修 | 无斜杠时用 `pwd` |

### 已知未修 / 接受的风险

| 编号 | 风险 | 原因 / 缓解 |
|---|---|---|
| A-01 | 前台 `MADV_PAGEOUT` 可能造成一次缺页 | 功能固有代价；`app_pageout=0` 可关 |
| A-02 | `drop_caches` 是全局操作 | 默认关、冷却 1800s |
| A-03 | `zram_enable=1` 仍可能按「内存一半」重建 zram（仅当未被 swapon 且设备空闲时） | 用户可设 `zram_enable=0`；卸载重启恢复 |
| A-04 | `kill_mode=am` 会结束整包后台 | `am kill` 语义如此；默认 `pid` |
| A-05 | 多用户/工作资料：cgroup 目录可能是 `uid_<appid>` 而非完整 uid | 未做双路径兜底；`only_frozen=0` 时走 `/proc` 不受影响 |
| A-06 | `app_relief.sh` 对目标 PID 未做 `starttime` 复核 | 只做 trim/pageout，不杀进程，风险低 |
| A-07 | helper 内部仍有 TOCTOU（先读 smaps 后 `pidfd_open`） | 失败只会换出 0 字节，不会误杀 |
| A-08 | 未检查 `mkswap/swapon/fallocate/cksum` 是否存在 | 失败会写日志并降级，不影响启动 |
| A-09 | 未在真机验证 | 发布说明必须写明；首刷 `dry_run=1` + `zram_enable=0` |
| A-10 | WebUI 无 CSRF 防护 | 只在本地 WebView 中可用，无网络暴露 |

### 构建产物核验

`bin/cirno_pageout` 已用 zig 0.18.0-dev.349 交叉编译并核验：

- `zig cc -target aarch64-linux-musl -static -Os -s`，退出码 0；
- 追加 `-Wall -Wextra -O2 -c` 编译无任何警告；
- ELF 头：64-bit LSB、`ET_EXEC`、`EM_AARCH64(183)`；
- 程序头：有 `PT_LOAD`，**无 `PT_INTERP`、无 `PT_DYNAMIC`**（静态、无解释器）；
- 大小 56,704 字节，打包进模块 zip 时权限 `0755`。

未在真机执行过 `--probe`；如果设备的内核不支持 `pidfd_open` / `process_madvise`，
`helper_ready()` 会把 `can_pageout` 置 0 并退化为纯 trim，WebUI 会显示「页换出：不可用」。

### 真机待验证清单

- [ ] `dumpsys activity activities` 的前台包名解析（AOSP / HyperOS / ColorOS / OriginOS）
- [ ] `am send-trim-memory <pid> RUNNING_LOW` 是否被接受（日志出现 `APP RELIEF` 即成功）
- [ ] `cgroup.freeze` 路径是否为 `/sys/fs/cgroup/apps/uid_*/pid_*/cgroup.freeze`
- [ ] `/proc/swaps` 里的 zram 设备名是 `/dev/block/zram0` 还是 `/dev/zram0`
- [ ] 手动 `kill -9` 掉 daemon，watchdog 是否在 30–60s 内拉起
- [ ] 卸载并重启后 `swapon -s` / `swappiness` 是否回到预期
- [ ] `bin/cirno_pageout --probe` 在目标内核的返回码
