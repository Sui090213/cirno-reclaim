# 参与贡献 / Contributing

感谢你愿意改进 Cirno Reclaim。这是一个需要 root 权限的系统级模块，错误可能结束用户的应用进程或影响前台体验，所以请优先保证**可回滚、可解释、默认安全**。

## 开始之前

- 小改动可以直接提 PR；涉及回收策略、默认阈值、SELinux、原生 helper 或卸载逻辑的改动，请先开 issue 描述动机和测试计划。
- 不要提交任何真实用户的日志、应用列表、设备序列号、账号信息或配置文件。
- 不要提交从网上复制的、来源不明的二进制文件。
- 提交即表示你同意以本项目的 GPL-3.0-only 许可证发布你的贡献。

## 项目结构

```text
bin/common.sh      共享函数、配置读取、日志、daemon 生命周期
bin/daemon.sh      常驻循环
bin/reclaim.sh     后台进程回收
bin/app_relief.sh  前台应用 trim / 页换出
bin/ctl.sh         状态、扫描、保存、重启等控制接口
src/               arm64 原生 helper 源码
webroot/           KsuWebUI 页面
config.conf        默认配置模板
```

## 开发环境

不需要 Android SDK 或 Gradle。推荐：

- POSIX shell（`/system/bin/sh` / BusyBox ash / mksh）；
- [ShellCheck](https://www.shellcheck.net/)；
- Node.js（只用于 `node --check`）；
- 可选：Zig 0.13+（重新编译 `bin/cirno_pageout`）。

## 代码风格

### Shell

- 目标解释器是 Android 的 `/system/bin/sh`，不要使用 bash 数组、`[[ ]]`、进程替换等 bashism。
- 变量一律加双引号：`"$pid"`、`"$file"`。
- 配置键保持小写；新增键必须在 `bin/common.sh` 的 `set_defaults`、`load_config`、`config.conf`、`bin/ctl.sh` 的 status/save 校验和 WebUI 中同步。
- 不要在循环里无意义地 fork 子 shell；配置归一化优先使用全局变量（参考 `norm_int`）。
- 日志中的包名/PID 可以记录，但不要记录用户内容、路径中的账号或其他隐私。
- 新增 kill 路径必须说明它如何避免前台、系统 UID、visible/服务进程。

### WebUI

- 不使用 CDN、远程字体、远程脚本或任何网络请求；CSP 已禁止 `connect-src`。
- 用户可控字符串必须用 `textContent`，不要拼 `innerHTML`。
- 不引入构建步骤；`webroot/` 直接由 KernelSU/KsuWebUI 提供。
- 保持 `ksu.exec` 兼容官方 KernelSU 和 KsuWebUIStandalone。

### 原生 helper

- 只提交能从 `src/` 重新编译的代码；提交二进制时同时提交源码和构建命令。
- `process_madvise` 只允许 `MADV_PAGEOUT`，不要改成 `MADV_DONTNEED`（会丢数据）。
- 只处理私有匿名映射；跳过 stack、code、GPU、Dalvik、JIT。
- 必须保留单次字节上限；失败要返回非零，让 shell 回退到 trim。

## 本地检查

提交前至少运行：

```sh
find . -name '*.sh' -exec sh -n {} \;
shellcheck -s sh bin/*.sh *.sh
node --check webroot/app.js
```

如果改了原生 helper：

```sh
cd src
zig cc -target aarch64-linux-musl -static -Os -s \
    -o ../bin/cirno_pageout cirno_pageout.c
```

检查 ELF 为 AArch64、静态、无外部依赖：

```sh
file bin/cirno_pageout
readelf -h bin/cirno_pageout
```

## 真机测试清单

在 PR 中描述测试设备：品牌/型号、Android 版本、内核版本、root 方案（Magisk/KernelSU/APatch）、cgroup 布局。

至少验证：

- [ ] 模块能正常刷入并开机；
- [ ] WebUI 能打开、状态能刷新；
- [ ] 配置保存后重启仍保留；
- [ ] `dry_run=1` 时日志只记录、不 kill；
- [ ] 关闭 dry-run 后只回收预期的已冻结缓存进程；
- [ ] 前台应用（浏览器/视频/聊天）使用时没有被结束；
- [ ] `app_relief` 日志出现，且前后 PSS/可用内存有变化或明确失败原因；
- [ ] 卸载后 `/data/adb/cirno_reclaim` 和模块 `log/` 均不存在。

> 不要在主力机上用支付、银行、2FA、电话、闹钟等关键应用做 kill 测试。测试前先备份配置。

## 提交信息

推荐 Conventional Commits：

```text
feat(app-relief): add foreground PSS watchdog
fix(save): do not fail on normalized config values
docs: clarify module-local log path
perf(webui): remove backdrop blur
```

PR 描述请包含：

1. 问题/动机；
2. 改动摘要；
3. 风险与回滚方式；
4. 测试环境与结果；
5. 是否影响配置兼容性。

## 安全

- 发现可被利用的 root 权限问题，请不要公开提交 issue，按 [SECURITY.md](SECURITY.md) 私下报告。
- 不要为了“效果更强”而默认降低 `min_oom_score_adj`、开启 `allow_system_uid` 或 kill 前台。
- 新增外部依赖、二进制或网络请求会被重点审查。

## 许可证

贡献代码按 **GPL-3.0-only** 授权。提交 PR 即表示你有权这样做，并同意项目以该许可证分发。
