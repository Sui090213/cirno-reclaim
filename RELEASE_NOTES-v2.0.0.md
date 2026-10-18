# Cirno Reclaim Hybrid v2.0.0

**Cirno 冻结器的配套内存回收模块** · Magisk / KernelSU / APatch · Android 12+

把「冻结但不释放」的后台内存真正还给系统，同时让前台应用主动吐出缓存；
附带 zram / swapfile / VM 调参和三层保活。

作者：flyingr · 反馈：asui20090213@outlook.com

---

## 这一版做了什么

由 **cirno-reclaim**（Cirno 派生）与 **HybridRAM** 合并而来，脚本重写、配置统一。

**回收更积极**
- 阈值双轨：`mem_low_mb` 与总内存百分比取较大值，12GB 机器不再套用 8GB 阈值
- PSI 触发：读 `/proc/pressure/memory`，内存看着够但系统已卡时也会回收
- 多轮迭代 + 单轮 4 个 / 每小时 20 个（上游 3 / 12），冻结 5 分钟即可回收（上游 10）
- 深回收：杀完仍不足时把冻结进程匿名页换出，不杀进程

**前台更有效**
- 对该包**所有进程**发 `send-trim-memory`，不只主进程
- 页换出分 3 轮、每轮重读 smaps 按 PSS 分配预算，单次上限 192MB
- 日志与 WebUI 直接给出 `PSS before → after` 和可用内存增量

**不再掉线**
- `service.sh` → `watchdog.sh` → `daemon.sh` 三层保活，pid + 命令行 + 心跳三重判断
- 看门狗反向检查 supervisor；重启有 20s/300s 节流；进程 `oom_score_adj=-900`
- `interval` / `heartbeat_timeout` 被 `cfg_clamp` 夹到安全区间，避免重启风暴

**WebUI 更简单**
- 三页：概览 / 设置 / 反馈；三个预设（保守 / 均衡 / 激进）
- 内置反馈页：邮箱、一键复制诊断信息、一键写邮件
- 纯静态、无框架、无 CDN、不联网

**安全**
- 配置文件**不再被 `source`**：逐行解析 + 键白名单 + 类型校验 + `case` 赋值，
  `;`/空格/`$(...)`/`#` 都不再可能变成命令
- pid 文件与单实例锁都核对命令行，锁改用 `mkdir` 原子实现
- kill 在解冻后重新校验 starttime / oom / 前台 / 保护名单，不满足就冻回去
- zram 重建增加 `/proc/swaps` 匹配、`swapoff` 失败即中止；swapfile 增加剩余空间检查

---

## 安装

1. 下载 `Cirno-Reclaim-Hybrid-v2.0.0.zip`
2. 在 Magisk / KernelSU / APatch 里「从本地安装」
3. 重启
4. KernelSU 用户：模块详情 → 打开 WebUI；Magisk 用 `action.sh` 或终端

**首次使用建议**：先设 `dry_run=1`、`zram_enable=0` 跑一轮，确认日志里是
`DRY would reclaim ...` 而不是报错，再切回正式模式。

---

## 包内容

- 25 个文件，约 116 KB
- 内置 arm64 `bin/cirno_pageout`（静态 ELF，无解释器，56 KB），源码在 `src/`
- 非 arm64 设备安装时自动移除 helper，前台降级为纯 trim

---

## 已知限制

- **尚未在真机完整验证**，首刷请按上面的安全流程；
- 前台页换出需要内核支持 `pidfd_open` + `process_madvise`，否则自动降级为 trim
  （WebUI 会显示「页换出：不可用」）；
- 需要 Cirno 本体才能真正「冻结」，本模块只负责回收；
- 卸载后 `swappiness` 等 sysctl 需重启恢复；
- 工作资料 / 多用户的 cgroup 可能是 `uid_<appid>` 布局，未做双路径兜底。

---

## 校验

Release 附件里的 `CHECKSUMS.txt` 是本次构建产物的 SHA-256：

```powershell
Get-FileHash Cirno-Reclaim-Hybrid-v2.0.0.zip -Algorithm SHA256
```

---

## 反馈

- Issue 请附机型、Android / 内核版本、root 方案、复现步骤、日志
- 安全相关问题请直接邮件：**asui20090213@outlook.com**
- 完整文档与审计记录见仓库 `README.md`、`SECURITY.md`、`docs/SECURITY-AUDIT.md`
