# 安全策略 / Security Policy

Cirno Reclaim 是一个拥有 root 权限的 Android 模块，会结束后台进程、对前台应用执行 trim，并可选地调用 `process_madvise(MADV_PAGEOUT)`。请把本项目当作**系统级工具**，而不是普通应用。

## 支持版本

| 版本 | 支持 |
|---|---|
| `1.3.x` | ✅ 当前安全修复 |
| `< 1.3` | ❌ 不再保证修复 |

## 报告漏洞

请不要在公开 issue 中提交可直接利用的 root 权限问题、命令注入 payload 或用户数据。

优先使用 GitHub 仓库的：

```text
Security → Report a vulnerability
```

如果仓库未开启 Private vulnerability reporting，请先开一个**不含利用细节**的 issue，说明“需要私下报告安全问题”，维护者会提供渠道。

报告请包含：

- 受影响版本；
- 设备/Android/内核/root 方案；
- 复现步骤；
- 影响（命令执行、任意文件删除、提权、隐私泄露等）；
- 建议修复方向（如有）。

## 威胁模型

### 信任边界

- 模块脚本以 root 运行；
- `/data/adb/cirno_reclaim` 属于 root，配置和数据不应对普通应用可写；
- KsuWebUI 通过 root shell 执行 `ctl.sh`；
- 原生 helper 只从模块目录执行，不接受用户提供的路径或任意命令；
- 模块不联网。

### 不在范围内

- 已经拥有 root 的恶意应用/用户：root 本身可以修改任何模块文件；
- Magisk/KernelSU/APatch 管理器自身漏洞；
- Cirno 本体漏洞；
- 用户手动把配置权限改成全局可写后造成的命令执行；
- 用户自行替换 `bin/cirno_pageout` 或修改脚本。

## 安全清单与审计结果

审计日期：2026-10-18，版本：v1.3.0。

| 检查项 | 结果 | 说明 |
|---|---|---|
| 无网络请求 / 遥测 | ✅ | 脚本和 WebUI 不包含网络调用 |
| 无硬编码密钥 | ✅ | 仓库不包含 token、证书、私钥 |
| 配置权限 | ✅ | `0600`，数据目录 `0700` |
| 日志权限 | ✅ | `umask 077`，日志 `0600`，目录 `0700` |
| 日志不泄露隐私 | ✅ | 仅包名、PID、PSS、线程数、配置值 |
| WebUI XSS | ✅ | 动态包名用 `textContent`；无远程资源；CSP 限制 `script-src 'self'`、`connect-src 'none'` |
| WebUI 命令注入 | ✅ | 保存值经过白名单校验；base64 载荷；列表值单引号包裹 |
| 后台 kill 范围 | ✅ | 应用 UID + `oom_score_adj>=900` + 默认 `cgroup.freeze=1` + 非前台 + 名单 |
| 前台 kill | ✅ | 前台路径不 kill；只 trim / 页换出 |
| 解冻失败处理 | ✅ | 放弃 kill，不留下冻结僵尸 |
| 竞态检查 | ✅ | 解冻后、kill 前复查 oom/包名 |
| 原生 helper 数据安全 | ✅ | 仅 `MADV_PAGEOUT`，不丢数据；跳过 stack/code/GPU/Dalvik/JIT |
| 原生 helper 权限 | ✅ | 只接受 PID + 上限；不执行 shell；失败回退 |
| 卸载路径可控 | ✅ | 数据/日志路径硬编码，不接受环境变量覆盖 |
| 卸载残留 | ✅ | 删除数据目录、模块 log、轮转日志、nohup.out |
| 打包内容 | ✅ | 发布 zip 不含 log/state/config.local/测试数据 |
| 供应链 | ⚠️ | arm64 helper 为预编译；源码和构建脚本已提供，发布时应附 SHA256 |
| 配置解析 | ⚠️ | 配置由 root 脚本 `source`；仅 root 可写，属于可接受风险 |

### 已修复/加固项

- `umask 077`，避免日志被其他用户读取；
- 数据目录和日志目录改为固定路径，避免环境变量把 `rm -rf` 或写入引到其他目录；
- WebUI 增加 CSP；
- 配置保存不再因归一化误报“回读错误”，但 `ctl.sh save` 仍验证真实写入/重命名；
- 日志移入模块目录，卸载时随模块清理。

## 已知风险

1. **root 模块本身**：任何能修改模块文件或配置的实体都已经拥有 root 能力。不要把 `/data/adb/cirno_reclaim` 改成全局可写。
2. **配置是 source 的**：`load_config` 使用 `. "$CONFIG_FILE"`，这是为了支持注释和带引号的列表。配置必须保持 `0600`、目录 `0700`；不要从不可信来源恢复配置。
3. **kill 会丢应用状态**：后台回收会丢失该进程的内存状态；这是设计目标，不是漏洞。先 `dry_run=1`。
4. **页换出可能造成短期卡顿**：`MADV_PAGEOUT` 把匿名页写入 zram，访问时换回。默认 128MB + 冷却；如不适配设置 `app_pageout=0`。
5. **OEM 差异**：cgroup 布局、`/proc/<pid>/reclaim`、`process_madvise` 可用性因内核而异；失败应安全回退，不应视为提权面。
6. **预编译二进制**：`bin/cirno_pageout` 是 arm64 静态 ELF，源码在 `src/cirno_pageout.c`。从非官方渠道下载的 zip 可能被替换；请核对 Release 提供的 SHA256，或自行编译。

## 用户安全检查

- [ ] 只从本仓库 Releases 下载；
- [ ] 核对发布页 SHA256；
- [ ] 首次使用 `dry_run=1` 观察；
- [ ] 不把 `allow_system_uid` 改为 `1`；
- [ ] 不把 `min_oom_score_adj` 调到 900 以下，除非明确知道风险；
- [ ] 不把配置/数据目录权限放宽；
- [ ] 关键应用（银行、2FA、电话、闹钟）加入 `exclude_packages`；
- [ ] 出现异常先看 `log/reclaim.log`，不要直接删除数据目录。

## 维护者发布检查清单

发布前逐项确认：

- [ ] `sh -n` 所有脚本通过；
- [ ] `shellcheck -s sh bin/*.sh *.sh` 无 error；
- [ ] `node --check webroot/app.js` 通过；
- [ ] 重新编译 `bin/cirno_pageout`，确认 AArch64 静态 ELF；
- [ ] zip 根目录直接包含 `module.prop`；
- [ ] zip 不包含 `log/`、`state/`、`config.local.conf`、测试文件、设备日志；
- [ ] 检查 `config.conf` 权限 `0600`；
- [ ] 在至少一台真机验证安装、保存、dry-run、前台舒缓、卸载；
- [ ] 卸载后 `/data/adb/cirno_reclaim` 和模块 `log/` 不存在；
- [ ] 生成并公布 SHA256；
- [ ] Release notes 说明默认值和风险变化；
- [ ] 不把用户日志/设备信息贴到公开 issue。

## 许可证与致谢

安全相关代码按 **GPL-3.0-only** 发布。第三方项目（Cirno、KernelSU、Magisk、APatch、Zig/musl）遵循各自许可证。
