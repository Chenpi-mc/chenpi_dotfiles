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
├── apps.conf         配置清单，两个脚本共用（加软件只改这里）
├── arch-install.sh   新机器恢复整套配置
├── dot_update.sh     本机配置同步进仓库
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

### 新机器一键安装（arch-install.sh）

克隆或拷贝仓库到任意位置，然后在仓库目录里运行：

```bash
git clone https://github.com/Chenpi-mc/chenpi_dotfiles
cd chenpi_dotfiles
./arch-install.sh
```

脚本按顺序做这么几件事：

| 步骤 | 做什么 |
|------|--------|
| 环境检查 | 确认是 Arch、有 pacman、没用 root 直接跑 |
| 临时免密 | 安装期间不反复问密码（规则临时写进 sudoers，退出自动删） |
| 备份现有配置 | 打包成 `~/dotfiles-backup-时间戳.tar.gz`，`/etc` 那份单独一个文件 |
| 安装软件包 | 按两份 pkglist 用 pacman / yay 装 |
| 恢复配置 | `.config/`、顶层 dotfile、壁纸、`/etc/sddm.conf` |
| 检查显示管理器 | 报出装了哪些 DM、启用了哪个，提醒别开多个 |
| 装后对账 | 逐个核对包在不在，缺的列出来 |

**重复运行是安全的**，已经完成的步骤会自动跳过，中途断了接着跑就行：

```bash
./arch-install.sh --force   # 忽略进度记录，全部重跑
./arch-install.sh --reset   # 只清空进度记录，不安装
```

进度记在 `.install_progress` 里，属于本机状态，不会上传到仓库。

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
| [shorin-arch-setup](https://github.com/SHORiN-KiWATA/shorin-arch-setup) | SHORiN-KiWATA | 桌面配置基础；`arch-install.sh` 的断点续传、tar 整包备份、显示管理器冲突检测、临时免密、装后对账这几条思路参考其 `install.sh` |
| [JaKooLit](https://github.com/JaKooLit) | JaKooLit | hyprlock 锁屏配置来源 |

`呜呜呜`
