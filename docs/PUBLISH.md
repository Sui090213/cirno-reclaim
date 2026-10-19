# 发布到 GitHub

仓库里已经准备好了 GitHub 需要的全部文件（README / LICENSE / .gitignore / CONTRIBUTING /
SECURITY / CODE_OF_CONDUCT / Issue 表单 / PR 模板 / Release workflow），
本文件只讲「怎么把它放到 GitHub 上」。

建议仓库名：`Cirno-Reclaim-Hybrid`
建议 owner：`flyingr`（如果不是，记得把 README 徽章、`webroot/index.html` 里的仓库地址、
`.github/ISSUE_TEMPLATE/config.yml` 的 Discussions 链接一起改掉）。

---

## 方式 A：网页上传（不装任何东西，最快）

1. GitHub → **New repository**
   - 名字：`Cirno-Reclaim-Hybrid`
   - 可见性：Public
   - **不要**勾选 Add README / .gitignore / license（我们已经有）
2. 解压 `dist/Cirno-Reclaim-Hybrid-v2.2.2-source.zip`，得到一堆文件。
3. 在新建的空仓库页点 **uploading an existing file**，把解压出来的**所有内容**拖进去。
   - Windows 资源管理器默认隐藏以 `.` 开头的文件，先打开「查看 → 显示 → 隐藏的项目」，
     否则 `.github/`、`.gitignore`、`.editorconfig`、`.gitattributes` 会漏掉。
4. Commit message 填 `v2.2.2: 整合 cirno-reclaim 与 HybridRAM`，提交。
5. 发布 Release：
   - Releases → **Draft a new release**
   - Tag：`v2.2.2`，Target：`main`
   - Title：`v2.2.2`
   - 正文：复制 `RELEASE_NOTES-v2.2.2.md` 的内容
   - 附件：上传 `dist/Cirno-Reclaim-Hybrid-v2.2.2.zip` 和 `dist/CHECKSUMS.txt`
   - Publish release

> 注意：网页上「创建 Release 时新建 tag」**不一定触发 Actions**（它产生的是 create 事件，
> 不是 push 事件）。所以这种方式下 CI 不会自动打包，直接用本地 `dist/` 里的产物即可。

---

## 方式 B：Git for Windows（推荐，能触发 CI）

```powershell
winget install --id Git.Git -e
# 装完重开一个终端，让 PATH 生效

cd "D:\Backup\Documents\deepseek-harness\default-workspace\Cirno-Reclaim-Hybrid"
git init -b main
git add .
git commit -m "v2.2.2: 整合 cirno-reclaim 与 HybridRAM"
git remote add origin https://github.com/flyingr/Cirno-Reclaim-Hybrid.git
git push -u origin main
git tag v2.2.2
git push origin v2.2.2
```

首次 `push` 会弹出浏览器让你登录（Git Credential Manager），授权一次即可。

`git push origin v2.2.2` 之后，`.github/workflows/release.yml` 会自动：
编译 arm64 helper → 跑 lint → 打包模块/源码 → 生成 `CHECKSUMS.txt` → 创建带附件的 Release。

---

## 方式 C：GitHub CLI（一条命令建仓）

```powershell
winget install --id GitHub.cli -e
gh auth login

cd "D:\Backup\Documents\deepseek-harness\default-workspace\Cirno-Reclaim-Hybrid"
git init -b main
git add .
git commit -m "v2.2.2: 整合 cirno-reclaim 与 HybridRAM"

gh repo create flyingr/Cirno-Reclaim-Hybrid --public --source=. --remote=origin --push
git tag v2.2.2
git push origin v2.2.2
```

---

## 仓库设置建议

| 项 | 值 |
|---|---|
| Description | `Cirno 冻结器的配套内存回收模块 · Magisk / KernelSU / APatch` |
| Topics | `android` `magisk` `kernelsu` `apatch` `lsposed` `memory` `zram` `swap` `cirno` |
| License | 选择 GPL-3.0（仓库里已有 LICENSE，GitHub 会自动识别） |
| Discussions | 打开，Issue 模板的「使用问题」链接指向它 |
| Releases | 附 `*.zip` 与 `CHECKSUMS.txt`，正文用 `RELEASE_NOTES-v2.2.2.md` |

---

## 发布前 30 秒检查

```powershell
cd "D:\Backup\Documents\deepseek-harness\default-workspace\Cirno-Reclaim-Hybrid"

# 1. 不该进仓库的东西
git status --short          # 不应出现 dist/、log/、state/、*.zip

# 2. 脚本语法
python tools/lint_sh.py .
node --check webroot/app.js

# 3. 打包与校验
python tools/pack.py
python tools/pack.py --source
python tools/checksums.py
python tools/checksums.py --verify

# 4. 哈希（对外发布时可贴）
Get-FileHash dist\*.zip -Algorithm SHA256 | Format-Table
```

没有 Python 的话，前两步可以跳过，直接用 `dist/` 里已经生成并校验过的产物。

---

## 出问题怎么办

- **push 提示 403 / 需要 token**：用 `git remote set-url origin https://<用户名>@github.com/...`，
  或者改用 `gh auth login` 后再 push；
- **Actions 没跑**：Settings → Actions → General，确认允许 workflow；
- **Actions 里 zig 安装失败**：把 `.github/workflows/release.yml` 里的 `mlugg/setup-zig`
  版本从 `0.13.0` 改成你本地能用的版本（你装的是 0.18.0-dev，本地已编译成功）；
- **Release 里没有 helper**：说明 CI 没编译成功，本地 `dist/*.zip` 里是带 helper 的，直接上传本地包即可。
