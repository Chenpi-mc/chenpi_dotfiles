# Git 上传配置到 GitHub —— 新手教程

> 以 `chenpi_dotfiles` 配置仓库为例，从头教到会。

## 事前准备

- 一个 GitHub 账号（https://github.com 注册）
- 一个空的 GitHub 仓库（网页上 New repository 创建，比如 `chenpi_dotfiles`）
- 本机有 git（Arch 上：`sudo pacman -S git`）

---

## 一、进入配置文件夹

```bash
cd ~/chenpi_file/chenpi_dotfiles
```

| 单词 | 意思 |
|------|------|
| `cd` | change directory，切换目录 |
| `~` | 家目录的缩写，即 `/home/chenpi` |

---

## 二、设置 git 身份（只做一次）

```bash
git config --global user.name "Chenpi-mc"
git config --global user.email "你的邮箱"
```

| 单词 | 意思 |
|------|------|
| `config` | 配置 |
| `--global` | 全局生效（不加就只对当前文件夹生效） |
| `user.name` / `user.email` | 提交时的作者署名 |

> 邮箱必须是 GitHub 注册用的那个。

---

## 三、把文件夹变成 git 仓库

```bash
git init
git branch -M main
```

| 单词 | 意思 |
|------|------|
| `init` | initialize，初始化（创建隐藏的 `.git/` 记录历史） |
| `branch -M main` | 把主分支重命名为 main（GitHub 默认主分支名） |

---

## 四、确认哪些文件会上传（防翻车关键步）

```bash
git status
```

`status` = 状态。重点检查列表里**没有**敏感文件（如 `.miyu-config-excluded`、`.pulse-cookie-excluded` 等）。这些由 `.gitignore` 文件负责挡住。

---

## 五、添加并提交

```bash
git add .
git commit -m "first commit"
```

| 单词 | 意思 |
|------|------|
| `add .` | 把所有文件加入待提交清单（暂存区），`.` 表示当前目录全部 |
| `commit -m "..."` | 正式提交，`-m` 后跟提交说明 |

---

## 六、关联远程仓库

```bash
git remote add dotfile https://github.com/Chenpi-mc/chenpi_dotfiles.git
```

| 单词 | 意思 |
|------|------|
| `remote add` | 添加远程仓库 |
| `dotfile` | 给远程仓库起的名字（也可叫 origin） |
| `https://...git` | 远程仓库地址 |

---

## 七、登录 GitHub（认证）

### 方式 A：gh 命令行（推荐）

```bash
sudo pacman -S github-cli    # 注意包名是 github-cli，不是 gh
gh auth login
```

交互选择：GitHub.com → HTTPS → Login with a web browser → 记下 one-time code → 浏览器打开 github.com/login/device 输入 code → 授权。

> 如果浏览器打开超时，先设代理：`export https_proxy=http://127.0.0.1:7890`（前提是本地有 Clash 类代理在跑）。

### 方式 B：PAT 令牌

GitHub 网页 → Settings → Developer settings → Personal access tokens → 生成 token → 推送时把 token 当密码输入。

---

## 八、推送

```bash
git push -u dotfile main
```

| 单词 | 意思 |
|------|------|
| `push` | 把本地记录上传到远程 |
| `-u` | 设置上游关联，以后直接 `git push` 即可 |
| `dotfile` | 推送到哪个远程 |
| `main` | 推哪个分支 |

---

## 以后日常更新（三连）

```bash
~/chenpi_file/chenpi_dotfiles/dot_update.sh   # 1. 同步本机配置到文件夹
cd ~/chenpi_file/chenpi_dotfiles
git add . && git commit -m "更新了xx配置"      # 2. 提交
git push                                       # 3. 推送
```

因为第一次用了 `-u`，之后 `git push` 不用打全名。

---

## 踩坑记录

1. **gh 找不到包**：包名是 `github-cli`，不是 `gh`。
2. **push 要密码**：先 `gh auth login` 完成认证；git 会自动用 gh 的凭证。
3. **连接超时**：国内直连 GitHub 常超时，配好代理即可，git 代理写在 `.gitconfig` 的 `[http] proxy` 里。
4. **敏感文件别传**：用 `.gitignore` 排除密钥、token、cookie 等；传了就是事故，删历史很麻烦。
5. **gh-proxy 坑**：`.gitconfig` 里不要写 `insteadOf` 重写规则指向 gh-proxy 镜像，会导致鉴权失败。

---

## 反过来：把仓库里的配置装到新机器

上面讲的是「本机 → GitHub」。反向操作（一台干净的新机器 → 恢复成现在这样）用仓库里的 `install.sh`：

```bash
git clone https://github.com/Chenpi-mc/chenpi_dotfiles
cd chenpi_dotfiles
./install.sh
```

`./arch-install.sh` 是个转发壳，跑它跟跑 `./install.sh` 一回事。

它是一堆模块按顺序跑的（`scripts/` 里一个文件一个模块），这些事它自己会处理：

- **装前自动备份**——现有配置打包成 `~/dotfiles-backup-时间戳.tar.gz`
- **断点续传**——中途失败或断网，重跑会跳过已完成的模块（`--force` 强制全部重来，`--list` 可以先看会跑哪些）
- **AUR 助手自己装**——先看已配置的源里有没有 yay / paru（archlinuxcn 这类社区源就有），源里真没有才从 AUR 自举 `yay-bin`
- **临时免密**——安装期间不反复问密码，退出时自动删掉规则
- **改系统前先打快照**——根分区是 btrfs 就配好 snapper，动配置前留还原点
- **装后对账**——逐个核对包在不在，缺的列出来

要同步哪些软件、壁纸在哪，都写在 `apps.conf` 里，两个脚本共用这一份清单。详细说明见 `README.md`。
