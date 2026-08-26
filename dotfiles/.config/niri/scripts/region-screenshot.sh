#!/usr/bin/env bash
# 区域截图：保存到磁盘并复制到剪贴板（保证截图后可直接粘贴）
set -euo pipefail

DIR="$HOME/Pictures/Screenshots/Niri-screenshots"
mkdir -p "$DIR"
FILE="$DIR/$(date +%Y-%m-%d_%H-%M-%S).png"

# slurp 选择区域，grim 截图
region="$(slurp -d 2>/dev/null)" || exit 1
grim -g "$region" "$FILE"

# 复制到剪贴板
wl-copy < "$FILE"

# 截图音效
if [ -f /usr/share/sounds/freedesktop/stereo/camera-shutter.oga ]; then
    pw-play /usr/share/sounds/freedesktop/stereo/camera-shutter.oga >/dev/null 2>&1 &
fi
