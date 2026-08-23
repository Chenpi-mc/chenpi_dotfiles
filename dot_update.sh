#!/usr/bin/env bash
# dot_update.sh — 把电脑上的配置同步到 chenpi_dotfiles 文件夹
# 用法：./dot_update.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HOME"
DEST="$SCRIPT_DIR"

# 要同步的 .config 软件（新增软件配置时在这里加一行）
CONFIG_APPS=(
  niri
  matugen
  fish
  kitty
  yazi
  nvim
  mpv
  btop
  fastfetch
  fuzzel
  mako
  waybar
  swayosd
  fcitx5
)

# 要同步的顶层 dotfile
TOP_FILES=(
  .bashrc
  .bash_profile
  .bash_logout
  .fbtermrc
  .vimrc
  .gtkrc-2.0
  .gitconfig
  .wget-hsts
)

# 要同步的顶层目录
TOP_DIRS=(
  .vim
  .icons
  .themes
  .miyu
)

# 同步 .miyu 时排除敏感项（API key、cookie、screen）
MIYU_EXCLUDES=(
  --exclude='config'
  --exclude='state/daemon-launch.json'
)

cd "$DEST"

echo "==> 同步 .config/"
mkdir -p "$DEST/.config"
for app in "${CONFIG_APPS[@]}"; do
  if [ -e "$SRC/.config/$app" ]; then
    rm -rf "$DEST/.config/$app"
    cp -r "$SRC/.config/$app" "$DEST/.config/"
    echo "    .config/$app ✓"
  else
    echo "    跳过 .config/$app（本机没有）"
  fi
done

echo "==> 同步顶层文件"
for f in "${TOP_FILES[@]}"; do
  if [ -e "$SRC/$f" ]; then
    rm -f "$DEST/$f"
    cp -a "$SRC/$f" "$DEST/"
    echo "    $f ✓"
  fi
done

echo "==> 同步顶层目录"
for d in "${TOP_DIRS[@]}"; do
  if [ -e "$SRC/$d" ]; then
    rm -rf "$DEST/$d"
    if [ "$d" = ".miyu" ]; then
      # 用 cp + 手动排除敏感项（不依赖 rsync）
      mkdir -p "$DEST/$d"
      cp -a "$SRC/$d/." "$DEST/$d/"
      for ex in config state/daemon-launch.json; do
        rm -rf "$DEST/$d/$ex"
      done
    else
      cp -a "$SRC/$d" "$DEST/"
    fi
    echo "    $d ✓"
  fi
done

echo "==> 同步 pkglist"
pacman -Qqe > "$DEST/pkglist.txt" 2>/dev/null || true
if command -v yay >/dev/null 2>&1; then
  yay -Qqm > "$DEST/pkglist-aur.txt" 2>/dev/null || true
fi

echo "==> 完成。chenpi_dotfiles 已更新，可以 git commit 了"
