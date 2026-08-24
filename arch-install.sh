#!/usr/bin/env bash
# arch-install.sh — 在新 Arch 机器上恢复整套配置
# 用法：./arch-install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/dotfiles"
echo "==> 配置仓库位置：$SRC"

if [ ! -d "$SRC" ]; then
  echo "错误：找不到 $SRC，先 clone 或拷入配置仓库再运行"
  exit 1
fi

# 备份旧配置
BACKUP="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
echo "==> 备份现有配置到 $BACKUP"
mkdir -p "$BACKUP"
for app in niri matugen fish kitty yazi nvim mpv btop fastfetch fuzzel mako waybar swayosd fcitx5 starship.toml fontconfig gtk-3.0 gtk-4.0 dconf autostart scripts cava MangoHud nwg-look glow satty xdg-desktop-portal user-dirs.dirs user-dirs.locale xsettingsd pulse pavucontrol.ini; do
  [ -e "$HOME/.config/$app" ] && mv "$HOME/.config/$app" "$BACKUP/"
done

# 铺回 .config
echo "==> 恢复 .config/"
mkdir -p "$HOME/.config"
for app in niri matugen fish kitty yazi nvim mpv btop fastfetch fuzzel mako waybar swayosd fcitx5 starship.toml fontconfig gtk-3.0 gtk-4.0 dconf autostart scripts cava MangoHud nwg-look glow satty xdg-desktop-portal user-dirs.dirs user-dirs.locale xsettingsd pulse pavucontrol.ini; do
  if [ -d "$SRC/.config/$app" ]; then
    cp -r "$SRC/.config/$app" "$HOME/.config/"
    echo "    .config/$app ✓"
  fi
done

# 铺回顶层 dotfile
echo "==> 恢复顶层 dotfile"
for f in .bashrc .bash_profile .bash_logout .fbtermrc .vimrc .gtkrc-2.0 .gitconfig .wget-hsts; do
  [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$HOME/" && echo "    $f ✓"
done
for d in .vim .icons .themes; do
  [ -d "$SRC/$d" ] && cp -a "$SRC/$d" "$HOME/" && echo "    $d ✓"
done

# 安装软件包
echo "==> 安装官方源软件包（pkglist.txt）"
if [ -f "$SRC/pkglist.txt" ]; then
  sudo pacman -S --needed - < "$SRC/pkglist.txt"
fi

echo "==> 安装 AUR 软件包（pkglist-aur.txt）"
if [ -f "$SRC/pkglist-aur.txt" ] && command -v yay >/dev/null 2>&1; then
  yay -S --needed - < "$SRC/pkglist-aur.txt"
elif [ -f "$SRC/pkglist-aur.txt" ]; then
  echo "    提示：未安装 yay，跳过 AUR 包（可自行 yay -S 安装）"
fi

echo "==> 完成！旧配置在 $BACKUP"
echo "==> 如果使用 niri，请从登录界面选择 niri 会话"
