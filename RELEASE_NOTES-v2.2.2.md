# Cirno Reclaim Hybrid v2.2.2

**Cirno 冻结器的配套内存回收模块** · Magisk / KernelSU / APatch · Android 12+

把「冻结但不释放」的后台内存真正还给系统，同时让前台应用主动吐出缓存；
附带 zram / swapfile / VM 调参和三层保活。

作者：flyingr · 反馈：asui20090213@outlook.com

---

## 这一版新增

**C++ 守护进程**

- 新增 `bin/cirno_daemon`（静态 arm64，无解释器），负责调度、心跳与子进程超时；
- 单调时钟，不受系统时间跳变影响；配置变更自动重读；
- 子进程硬超时：`dumpsys` 卡住时直接 SIGKILL，不会拖死整个守护；
- `mkdir` 原子锁 + 命令行校验，避免双实例；
- `--status` / `--check` / `--once` / `--foreground` 方便排障；
- 配置 `daemon_engine=shell` 或二进制缺失时自动回退旧 shell 守护。

**WebUI 重做（HyperOS 控制台风格）**

- 四页：控制台 / 场景 / 外观 / 关于；
- 控制台：圆环仪表、可用内存、累计回收与释放、守护引擎、页换出状态、四个动作按钮、设备信息、日志、自检；
- 场景：保守 / 均衡 / 激进三个预设 + 常用设置 + 高级参数；
- 外观：跟随系统 / 浅色 / 深色、四种强调色、纯色或图片背景、组件透明度；
- 关于：版本、作者、邮箱、一键复制诊断、写邮件。

**排障能力**

- `ctl.sh doctor`：路径 / 权限 / 引擎 / helper 探针 / 内核 / SELinux / 配置状态；
- `ctl.sh info`：设备与引擎 JSON；
- `ctl.sh log`：直接读日志文件，带路径、大小、行数与最近 200 行；
- `ctl.sh config`：配置缺失自动恢复，读不到时明确报错。

## 这一版修复

- **配置无法读取**：命令改用 `/system/bin/sh` 绝对路径；配置读取失败时禁用保存并显示原始 `errno/stderr`；
- **日志无法显示**：日志区直接读文件，支持手动/自动刷新，文件不存在时说明原因；
- **刷入包夹带无关文件**：模块 zip 改为运行期白名单，只留脚本、`bin/`、`webroot/`、`config.conf`、
  `LICENSE` 与原生源码；
- **配置解析死循环风险**：`cfg_load` 先补齐末尾换行再逐行读；
- **PATH 不完整**：脚本入口补齐 `/system/bin` 等路径。

## 安装

1. 下载 `Cirno-Reclaim-Hybrid-v2.2.2.zip`
2. 在 Magisk / KernelSU / APatch 里「从本地安装」
3. 重启
4. KernelSU 用户：模块详情 → 打开 WebUI；Magisk 用 `action.sh` 或终端

**首次使用**：先设 `dry_run=1`、`zram_enable=0` 跑一轮，确认日志是 `DRY would reclaim ...`，
再切回正式模式。

## 包内容

- 运行期文件 + `LICENSE` + `src/cirno_pageout.c`、`src/cirno_daemon.cpp`
- 内置 `bin/cirno_pageout`（C，约 56 KB）与 `bin/cirno_daemon`（C++，约 200 KB），均静态
- 非 arm64 设备安装时自动移除原生组件并回退 shell

## 已知限制

- **尚未在真机完整验证**，首刷请按上面的安全流程；
- C++ 守护只做调度，回收逻辑仍在 shell 里，问题仍以日志为准；
- 前台页换出需要内核支持 `pidfd_open` + `process_madvise`，否则自动降级为 trim；
- 需要 Cirno 本体才能真正「冻结」；
- 本地背景图只保存在 WebView，清数据会丢失。

## 校验

Release 附件里的 `CHECKSUMS.txt` 是本次构建产物的 SHA-256：

```powershell
Get-FileHash Cirno-Reclaim-Hybrid-v2.2.2.zip -Algorithm SHA256
```

## 反馈

- Issue 请附机型、Android / 内核版本、root 方案、复现步骤、日志
- 安全相关问题请直接邮件：**asui20090213@outlook.com**
- 完整文档与审计记录见仓库 `README.md`、`SECURITY.md`、`docs/SECURITY-AUDIT.md`
