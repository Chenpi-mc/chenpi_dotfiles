# 🐱 chenpi_dotfiles

> 基于 Arch Linux + niri 的个人配置同步仓库，我的第一个项目，请多多指教~

## 📦 包含内容

- **桌面环境**：niri（scroll-tiling Wayland 合成器）
- **终端**：kitty + fish + starship
- **工具**：yazi、nvim、btop、fastfetch、fuzzel、mpv
- **美化**：matugen、waybar、mako、swayosd
- **输入法**：fcitx5
- **软件包清单**：pkglist.txt / pkglist-aur.txt

## 🚀 使用方法

### 新机器一键安装（arch-install.sh）

克隆或拷贝仓库到任意位置，然后在仓库目录里运行：

```bash
cd chenpi_dotfiles
./arch-install.sh
```

脚本会：

1. 备份现有配置到 `~/.dotfiles-backup-时间戳/`
2. 恢复 `.config/` 下的软件配置和顶层 dotfile
3. 按 `pkglist.txt` 用 pacman 安装官方源软件包
4. 按 `pkglist-aur.txt` 用 yay 安装 AUR 软件包

> 脚本使用相对路径，仓库放哪都能跑，不依赖固定位置。

