#!/usr/bin/env bash
# dot_update.sh — 把电脑上的配置同步到 chenpi_dotfiles 文件夹
# 用法：./dot_update.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HOME"
DEST="$SCRIPT_DIR/dotfiles"

# 清单统一放在 apps.conf，两个脚本共用（加东西只改那一处）
if [ ! -f "$SCRIPT_DIR/apps.conf" ]; then
  echo "错误：找不到 apps.conf（配置清单）" >&2
  exit 1
fi
source "$SCRIPT_DIR/apps.conf"

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
    mkdir -p "$DEST/$d"
    cp -a "$SRC/$d/." "$DEST/$d/"
    if [ "$d" = ".miyu" ]; then
      for ex in "${MIYU_EXCLUDES[@]}"; do
        rm -rf "${DEST:?}/$d/$ex"
      done
    fi
    echo "    $d ✓"
  fi
done

# 壁纸目录（别把整个 chenpi_file 丢进 TOP_DIRS，那会让仓库把自己拷进自己）
echo "==> 同步壁纸"
WALLPAPER_SRC="$SRC/$WALLPAPER_DIR"
WALLPAPER_DEST="$DEST/$WALLPAPER_DIR"
if [ -d "$WALLPAPER_SRC" ]; then
  rm -rf "$WALLPAPER_DEST"
  mkdir -p "$WALLPAPER_DEST"
  cp -a "$WALLPAPER_SRC/." "$WALLPAPER_DEST/"
  # 模糊壁纸缓存是指向 ~/.cache 的软链接，不进仓库
  for ex in "${WALLPAPER_EXCLUDES[@]}"; do
    rm -f "$WALLPAPER_DEST/$ex"
  done
  echo "    壁纸 ✓（$(find "$WALLPAPER_DEST" -type f | wc -l) 个文件）"
else
  echo "    跳过（$WALLPAPER_DIR 不存在）"
fi

echo "==> 同步系统级配置（/etc）"
for f in "${ETC_FILES[@]}"; do
  if [ -f "$f" ]; then
    rel="${f#/etc/}"
    mkdir -p "$SCRIPT_DIR/etc/$(dirname "$rel")"
    cp -a "$f" "$SCRIPT_DIR/etc/$rel"
    echo "    $rel ✓"
  fi
done

echo "==> 同步 pkglist"
# 用 -Qqen（native 只在官方源里的），AUR 包交给下面那份清单，避免两份重复
pacman -Qqen > "$DEST/pkglist.txt" 2>/dev/null || true
if command -v yay >/dev/null 2>&1; then
  yay -Qqm > "$DEST/pkglist-aur.txt" 2>/dev/null || true
fi

echo "==> 完成。chenpi_dotfiles 已更新，可以 git commit 了"
