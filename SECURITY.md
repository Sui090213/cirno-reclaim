# 安全策略

这是一个**拥有 root 权限、会结束后台进程、会改写 VM / zram 参数**的系统级模块。
使用前请理解下面这些边界。本文同时是发布前的检查清单。

---

## 1. 威胁模型

模块以 root 运行，会读 `/proc`、写 `/proc/sys/vm`、写 cgroup、`kill -9` 缓存进程、
可能重建 zram / swapfile。它**不监听网络、不接收外部指令、不上传数据**，
所有行为由本地配置驱动。

| 资产 | 说明 |
|---|---|
| 用户数据 | 模块不读取应用私有数据，只读 `smaps` / `status` 里的统计数字 |
| 系统稳定性 | 误杀后台导致冷启动；页换出导致短时缺页；错误 zram 配置影响续航 |
| root 权限 | `config.conf` 由 root 脚本加载，只应由 root 修改 |

主要威胁：

1. 其他应用通过可写目录篡改配置 → 目前配置在 `0700` 目录、`0600` 文件，其他应用不可写；
2. 配置内容被当成 shell 代码执行 → 见第 4 节的准入校验；
3. 参数组合导致误杀关键进程 → 见第 3 节硬保护与限额；
4. WebUI 被注入 → 见第 5 节。

---

## 2. 不做什么

- 不杀线程（共享地址空间，必崩）；
- 不杀前台进程、不杀系统关键进程；
- 不修改 `system` / `vendor` 分区；
- 不注入任何进程、不 hook；
- 不联网、不收集遥测；
- 不在未确认内核能力时强行使用 `process_madvise`。

---

## 3. 安全边界

### 3.1 后台回收（会结束进程）

只有**同时**满足以下条件才会被回收：

- 应用 UID：`uid % 100000 ∈ [10000, 19999]`（`allow_system_uid=1` 才放宽，默认关）；
- `oom_score_adj >= 900`（缓存级）；
- `only_frozen=1` 时要求进程处于冻结状态（`cgroup.events` 的 `frozen 1`，或 `cgroup.freeze = 1`；
  `apps/uid_*/pid_*` 与 `uid_*/pid_*` 两种布局都认）；
- 非当前前台包（`protect_foreground=1`）；
- 不在硬保护名单、不在 `exclude_packages`、命中 `include_packages`（若配置）；
- `PSS >= min_process_mb`；
- 已冻结 `>= min_frozen_min` 分钟。

并且受四层限额约束：单轮上限、每小时上限、批次上限（`max_rounds`）、回收冷却。

### 3.2 硬编码保护

`android`、`com.android.systemui`、`com.android.shell`、电话 / 电信 / 蓝牙 / NFC / 设置 /
权限控制器 / GMS、Magisk / KernelSU / KernelSU Next / SukiSU / APatch 管理器、KsuWebUI、LSPosed、Shizuku、Cirno 本体，
ColorOS 的桌面、athena、电池、安全中心、HeyTap 推送 / 账号等组件，
以及运行时解析出的**桌面**与**默认输入法**。

### 3.3 前台舒缓（永不结束进程）

- 只在内存紧张时自动执行（手动按钮除外）；
- 只发 `am send-trim-memory`；
- 只对私有匿名页做 `MADV_PAGEOUT`，总量严格受 `app_pageout_max_mb` 限制（按常驻匿名页记账）；
- 跳过 stack / vdso / vvar / code / GPU / Dalvik / JIT / `/dev/` / `/system/` / `/apex/`；
- 内核不支持时自动降级为纯 trim。

### 3.4 竞态检查

kill 前重新核对 starttime、`oom_score_adj`、保护名单、前台状态与冻结状态。
冻结状态下直接 SIGKILL（cgroup v2 冻结进程可被致命信号结束），不先解冻，
因此没有「解冻后应用运行」的窗口；只有 1 秒后仍存活时才解冻重试，失败则冻回去。
pid 被复用的情况用「pid + starttime」校验排除。

### 3.4.1 冻结进程换出

`deep_reclaim` 只换出**已冻结**候选的私有匿名页（含 ART 堆，与 Android 对缓存进程的 full compaction 一致），
受 `deep_pageout_max_mb` 限制；进程不结束，下次访问时由内核换回。

### 3.5 文件权限

`/data/adb/cirno_reclaim` → `0700`；`config.conf`、状态文件、日志 → `0600`；进程 `umask 077`。

---

## 4. 配置解析（v2.0.0）

**`config.conf` 不会被 `source`。** 这一点是硬约束：只要配置文件被 shell 执行，
`;`、空格、`$(...)` 就都能变成命令。

当前流程（`bin/common.sh`）：

1. `cfg_defaults()` 先把所有键设成默认值；
2. 逐行读取，只接受「空行 / 注释行 / `KEY=VALUE`」，其它行计数后丢弃；
3. 键必须通过 `cfg_key_allowed()` 白名单（`PATH=`、`LD_PRELOAD=` 这类直接拒绝）；
4. 行内注释只认「空白 + `#`」；`#` 出现在别的位置说明这行不可信，整行丢弃；
5. 值按类型校验 `cfg_value_type_ok()`：
   - 数字键：只能是 `[0-9]+`；
   - `kill_mode` / `app_trim_level` / `profile` / `zram_algorithm`：精确枚举；
   - `include_packages` / `exclude_packages`：限定字符集 `A-Za-z0-9 _ . : ; * / + = , 空格 -`；
6. 通过后由 `cfg_assign()` 的 `case` 做**直接赋值**，值不会再回到 shell 解析；
7. `cfg_clamp()` 把 `interval`、`watchdog_interval`、`heartbeat_timeout`、`boot_delay`、
   `log_max_kb` 等夹到安全区间（例如 `interval` 至少 5 秒，`heartbeat_timeout ≥ 3×interval`）。

`ctl.sh save` / `set` 复用同一套类型校验与范围校验，并且**所有值都加单引号**写入，
所以 WebUI 和命令行都无法把 `$`、反引号、换行、分号写进配置并让它们生效。

> 代价：配置文件是「数据文件」，不是 shell 脚本。写 `x=$(reboot)` 不会执行，
> 只会被当成非法行忽略，并在日志里留下 `WARN config: N invalid line(s) ignored`。

---

## 5. WebUI

- 纯静态 `webroot/`，无 CDN、无 fetch、无第三方脚本；
- 所有动态文本用 `textContent` 写入，不用 `innerHTML` 拼接外部数据；
- 只通过 `ksu.exec` 调用固定命令，参数为白名单键值与数字；
- 非 KernelSU 环境打开时显示提示条，所有按钮拒绝执行。

---

## 6. 已知风险（用户需自行判断）

| 风险 | 影响 | 缓解 |
|---|---|---|
| 误杀后台 | 下次打开冷启动 | 选 `conservative` 预设，或调高 `min_frozen_min` |
| 前台页换出 | 偶发缺页/卡顿 | `app_pageout=0` |
| `drop_caches` | IO 变慢 | 默认关，冷却 1800s |
| zram 重建 | 续航/性能变化 | 默认关；ColorOS 上无论配置如何都不重建 |
| 冻结应用被压缩 | 切回时短暂缺页 | `deep_reclaim=0` 或调小 `deep_pageout_max_mb` |
| `swapfile_enable=1` | 占用存储、闪存写入 | 默认关 |
| `allow_system_uid=1` | 可能杀系统进程 | 默认关，不建议开 |
| 配置文件被 root 应用篡改 | 等于 root 执行 | 目录 `0700`，且加载前有准入校验 |

---

## 7. 发布检查清单

发布新版本前逐项确认（打勾后再上传 Release）：

**版本与元数据**

- [ ] `module.prop` 的 `version` / `versionCode` 已递增，`versionCode` 单调递增
- [ ] `README.md` 里所有出现的版本号、下载文件名已同步
- [ ] `CHANGELOG.md` 已写清新增 / 变更 / 修复 / 已知限制
- [ ] `LICENSE` 存在且与 README 声明一致（GPL-3.0-only）

**代码质量**

- [ ] `python3 tools/lint_sh.py .` 通过（0 error）
- [ ] `node --check webroot/app.js` 通过
- [ ] 所有 `.sh` 为 LF 换行、无 BOM（CRLF 在 Android 上必崩）
- [ ] 没有把 `log/`、`state/`、`dist/`、`*.zip`、本机配置提交进仓库
- [ ] 新增配置项同时更新：`config.conf`、`cfg_defaults()`、`cfg_key_allowed()`、README 配置表

**安全**

- [ ] 新增的 `kill` / `rm` / `swapoff` / `drop_caches` 目标都有边界与白名单
- [ ] 所有来自 `/proc`、配置、WebUI 的字符串都不会拼进命令（要么数字，要么过安全字符集）
- [ ] 前台路径没有引入「结束进程」的行为
- [ ] 硬保护名单仍然覆盖桌面、输入法、电话、系统 UI、root 管理器、Cirno
- [ ] 非 root 环境下 WebUI 不会执行任何 `ksu.exec`

**包结构**

- [ ] `module.prop` / `customize.sh` / `service.sh` / `post-fs-data.sh` 在 zip **根目录**
- [ ] 脚本权限 `0755`，其余 `0644`
- [ ] 包内不含 `bin/cirno_pageout` 时，README 明确说明前台只做 trim
- [ ] 含 helper 时，源码 `src/cirno_pageout.c` 与构建脚本同时提供（GPL 要求）
- [ ] `dist/*.zip` 的 SHA-256 与 `CHECKSUMS.txt` 一致

**升级与卸载**

- [ ] 从上一版本覆盖升级：配置保留、新增键自动补默认值
- [ ] `uninstall.sh` 能停进程、删 `/data/adb/cirno_reclaim`、删模块日志
- [ ] 卸载后重启，系统内存行为回到出厂（不残留 sysctl/swap 配置）

**发布**

- [ ] 打 tag（`vX.Y.Z`）后 CI 通过，Release 附带 `*.zip` 与 `CHECKSUMS.txt`
- [ ] Release 说明里写清适用条件（Android 12+、需要 Cirno、helper 是否内置）

---

## 8. 审计记录

每个版本的逐项审计（含已知未修复项）见 [docs/SECURITY-AUDIT.md](docs/SECURITY-AUDIT.md)。

---

## 9. 报告漏洞

本分支（ColorOS 17 适配）的问题请到 <https://github.com/yishisanren/cirno-reclaim/issues>。
请**不要**在公开 Issue 里贴可复现的 root 利用细节：先开一个不含细节的 Issue 说明需要私下沟通，
或使用仓库的 GitHub Security Advisory（私密报告）。

原版（flyingr）通用逻辑的问题也可以联系原作者：asui20090213@outlook.com。

请包含：受影响版本、复现步骤、影响范围、你的修复建议。
