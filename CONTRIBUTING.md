# 参与贡献

欢迎各种形式的反馈：兼容性报告、误杀/漏杀日志、文档改进、WebUI 优化、原生 helper 修复。

参与本项目即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。

---

## 反馈问题

**优先用 GitHub Issue**（模板已经写好，会要求填机型 / 版本 / 日志），
涉及 root 安全细节的请直接发邮件到 **asui20090213@outlook.com**，不要公开提交。

Issue 里请附上：

1. 机型、Android 版本、内核版本（`uname -r`）；
2. root 方案与版本（Magisk / KernelSU / APatch）；
3. 复现步骤（游戏、切后台、息屏、开机多久之后）；
4. 诊断信息：

```sh
sh /data/adb/modules/cirno_reclaim/bin/ctl.sh diag
```

5. 相关日志：

```sh
tail -n 200 /data/adb/modules/cirno_reclaim/log/reclaim.log
```

也可以直接在 WebUI「反馈」页点「复制诊断信息」，粘贴到 Issue 或邮件里。

---

## 提 PR 之前

### 1. 代码约定

- **只用 POSIX sh**。Android 上是 mksh：不要用 `[[ ]]`、数组、`$'...'`、`+=`、here-string；
- 变量一律加引号：`"$var"`；数字比较前先确认非空；
- 所有「可能失败」的操作都必须能降级：helper 缺失、内核不支持、`/proc` 不可读；
- 不要写死与机型相关的东西；
- 注释用中文，术语保留英文（cgroup / PSS / zram）。

### 2. 新增配置项要改四处

1. `config.conf`（带注释与默认值）；
2. `bin/common.sh` 的 `cfg_defaults()`；
3. `bin/common.sh` 的 `cfg_key_allowed()`；
4. `README.md` 的配置表。

值的字符集必须能通过 `cfg_value_type_ok()`（数字 / 精确枚举 / 名单字符集 `A-Za-z0-9 _ . : ; * / + = , 空格 -`），
否则 `ctl.sh save` 会拒绝写入，`cfg_load` 也会在启动时把它当非法行忽略。

### 3. 本地检查

```sh
# 一条命令跑完所有静态检查（编码/换行、shell lint、JS 语法、配置键一致性、
# 运行期文件与打包白名单、原生组件架构、版本号）
python3 tools/verify.py

# 或者分步
python3 tools/lint_sh.py .          # shell 语法 + 结构 + bashism
node --check webroot/app.js         # WebUI
python3 tools/pack.py               # 打包
python3 tools/checksums.py          # 生成 dist/CHECKSUMS.txt
python3 tools/checksums.py --verify # 校验

# 如果本机有 shellcheck（强烈建议）
find . -name '*.sh' -exec sh -n {} \;
shellcheck -s sh bin/*.sh *.sh
```

CI 会重复执行上面除 `shellcheck` 与原生编译之外的步骤，所以本地过不了 CI 也过不了。

### 4. 编译 helper（可选）

```sh
cd src && ./build.sh
```

需要 zig 0.13+，或设置 `CC` 指向 aarch64 的 clang（NDK 的 `aarch64-linux-android24-clang`）。
helper 是可选组件，不编译也能合入，但 Release 里带 helper 的包前台效果更好。

`bin/` 下的两个二进制是可复现构建：用 zig 0.18.0-dev.349 交叉编译，同样的源码能编出
字节完全一致的文件，所以改完 `src/` 记得重新编译并 `python3 tools/verify.py` 确认架构正确。

---

## 代码结构速查

| 文件 | 职责 | 改动风险 |
|---|---|---|
| `bin/common.sh` | 日志、内存读数、PSS、冻结检测、配置准入、进程管理 | 高（所有脚本依赖） |
| `bin/reclaim.sh` | 后台回收：候选筛选、排序、解冻、kill、深回收 | 高（会杀进程） |
| `bin/app_relief.sh` | 前台舒缓：trim + 多轮 pageout | 中（不杀进程） |
| `bin/daemon.sh` | 主循环、心跳、调度 | 中 |
| `bin/watchdog.sh` | 保活：心跳超时重启 daemon | 中（容易写出重启风暴） |
| `bin/vm_tune.sh` | zram / swapfile / sysctl | 高（改系统内存配置） |
| `bin/ctl.sh` | WebUI / CLI 的统一入口、JSON、配置写入 | 中 |
| `service.sh` | 开机入口 + 最外层守护循环 | 高（写错会影响开机） |
| `webroot/*` | KsuWebUI | 低 |

---

## 提交信息

```
feat: 新增 xxx
fix: 修复 xxx
tune: 调整默认阈值
docs: ...
```

一个 PR 只做一件事，说明「改了什么 / 为什么 / 怎么验证的」。
不要把 `log/`、`state/`、`dist/`、`*.zip` 提交进来。

---

## 发布

维护者流程见 [SECURITY.md](SECURITY.md) 第 7 节「发布检查清单」，
以及 [README.md](README.md#发布到-github)。
