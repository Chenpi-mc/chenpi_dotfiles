# 🐱 chenpi_dotfiles

> 基于 Arch Linux + niri 的个人配置同步仓库，我的第一个项目，请多多指教~
>> 我是真的萌新 ！！！

---
## 📦 包含内容

- **桌面环境**：niri（scroll-tiling Wayland 合成器）
- **终端**：kitty + fish + starship
- **工具**：yazi、nvim、btop、fastfetch、fuzzel、mpv
- **美化**：matugen、waybar、mako、swayosd
- **输入法**：fcitx5
- **壁纸**：`dotfiles/chenpi_file/wallpaper/`
- **软件包清单**：`dotfiles/pkglist.txt`（官方源）/ `dotfiles/pkglist-aur.txt`（AUR）

## 目录结构

```text
chenpi_dotfiles/
├── install.sh        装机主控（模块循环、断点续传、可选模块菜单）
├── arch-install.sh   转发壳，等价于 install.sh（照顾老习惯）
├── dot_update.sh     本机配置同步进仓库
├── apps.conf         配置清单，所有脚本共用（加软件只改这里）
├── scripts/          各个安装模块
│   ├── 00-utils.sh           公共函数库（颜色、日志、装包封装）
│   ├── 00-btrfs-init.sh      snapper 快照 + GRUB 快照菜单
│   ├── 01a-base.sh           基础系统配置
│   ├── 04-restore-config.sh  配置 / 壁纸恢复（核心）
│   ├── 05-verify.sh          装后对账
│   └── ...                   其余模块见下表
├── dotfiles/         $HOME 的镜像
│   ├── .config/      各个软件的配置
│   ├── .vim/ .icons/ .themes/ ...
│   ├── chenpi_file/wallpaper/   壁纸
│   ├── pkglist.txt       官方源软件包清单
│   └── pkglist-aur.txt   AUR 软件包清单
├── etc/              /etc 下的系统配置（sddm 登录界面）
└── LICENSE           AGPL-3.0
```

## 🚀 使用方法

### 新机器一键安装

克隆或拷贝仓库到任意位置，然后在仓库目录里运行：

```bash
git clone https://github.com/Chenpi-mc/chenpi_dotfiles
cd chenpi_dotfiles
./install.sh
```

`./arch-install.sh` 是个转发壳，跑它跟跑 `./install.sh` 一回事。

跑起来是一个个模块按顺序执行，每个模块只管一件事：

| 模块 | 干什么 |
|------|--------|
| `00-preflight` | **动手前先体检**：发行版、内核、CPU、内存、显卡、磁盘空间、btrfs 子卷、引导器、显示管理器、网络、时区语言、编译依赖、仓库自检全查一遍，结果写报告；撞到致命问题会拦下整个流程 |
| `00-btrfs-init` | 装 snapper、给 `@` 和 `@home` 配快照、集成进 GRUB 快照菜单，再打一个「装系统之前」的还原点 |
| `01a-base` | keyring、编辑器、multilib、中文字体、TTY 字体、locale、archlinuxcn 源、AUR 助手 |
| `02b-musthave` | 音频栈（pipewire）、输入法（fcitx5 + rime）、蓝牙（**检测到硬件才装**）、常用工具、pacman 彩色进度条 |
| `02c-dualboot-fix` | os-prober 找 Windows，打开 `GRUB_DISABLE_OS_PROBER=false`，重建引导 |
| `03b-gpu-driver` | `lspci` 认显卡类型，再用 chwd 自动装驱动（N 卡 / AMD / Intel） |
| `03c-snapshot-*` | 改桌面配置**之前**再打一个还原点当退路 |
| `04-restore-config` | **核心步骤**：先把现有配置打 tar 备份，再恢复 `.config`、顶层 dotfile、壁纸、`/etc/sddm.conf` |
| `07-grub-theme` | GRUB 主题（优先官方源的 `grub-theme-vimix`，没有就用系统里已有的主题） |
| `99-apps` | 按 `dotfiles/pkglist*.txt` 把 190 + 16 个包装回来 |
| `05-verify` | **最后一步**：逐个核对包、关键配置、壁纸是否到位 |

系统检查的报告在 `/tmp/chenpi-preflight.txt`，跑完会复制一份到 `~/Documents/装机前系统检查.txt`。报告里出现「致命」时会停下不装（比如不是 Arch、在 Live 环境跑、磁盘不足 5G）；确认无误要强行继续可以设 `CHENPI_IGNORE_PREFLIGHT=1` 再跑。
还有几个可选模块，跑的时候会用 fzf 列出来让你勾（不想交互就加 `--yes`，按默认走）。

| 参数 | 作用 |
|------|------|
| （不加） | 正常跑，已完成的模块自动跳过 |
| `--yes` | 全程不问问题，按默认选择（无人值守） |
| `--list` | 只列出这次会跑哪些模块，不执行 |
| `--force` | 忽略进度记录，全部重跑 |
| `--reset` | 只清空进度记录，不安装 |

**中途断了直接重跑就行**，已经完成的模块会跳过：

```bash
./install.sh          # 接着上次没跑完的继续
./install.sh --force  # 全部重来
```

进度记在 `.install_progress` 里，属于本机状态，不会上传到仓库。整个过程会写一份日志到 `/tmp/chenpi-install.log`，跑完还会往 `~/Documents/` 存一份。

### 本机配置更新（dot_update.sh）

改完配置后，把本机状态同步进仓库并推上去：

```bash
./dot_update.sh
git add .
git commit -m "更新配置"
git push
```

### 加新软件只改一处

要同步的清单全在 **`apps.conf`**。比如新装了 `zathura`，想同步它的配置：

1. 打开 `apps.conf`，在 `CONFIG_APPS` 里加一行 `zathura`
2. 跑一次 `./dot_update.sh`，配置就进来了

装包清单是自动生成的（`pacman -Qqen` 出官方源那份，`yay -Qqm` 出 AUR 那份），不用手写。

**脚本用相对路径，仓库放哪都能跑，不依赖固定位置。**

## 授权

本仓库采用 **AGPL-3.0**，全文见 [LICENSE](LICENSE)。

配置和脚本基于下面这些项目修改而来，版权归原作者所有：

| 项目 | 作者 | 用到了什么 |
|------|------|-----------|
| [shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup) | SHORiN-KiWATA | 桌面配置基础；整套装机脚本的结构（`install.sh` 主控 + `scripts/NN-*.sh` 模块 + 断点续传 + tar 整包备份 + 显示管理器冲突检测 + 临时免密 + 装后对账 + btrfs/snapper 快照 + GRUB 集成）都照它的思路改写 |
| [JaKooLit](https://github.com/JaKooLit) | JaKooLit | hyprlock 锁屏配置来源 |

`呜呜呜`
