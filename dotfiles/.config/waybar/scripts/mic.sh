#!/bin/bash
# 显示默认麦克风状态：󰍬 音量% / 󰍭 静音
muted=$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null)
pct=$(pactl get-source-volume @DEFAULT_SOURCE@ 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
if [ -z "$pct" ]; then
    pct=0
fi
if echo "$muted" | grep -q "yes"; then
    echo "󰍭"
else
    echo "󰍬${pct}%"
fi
