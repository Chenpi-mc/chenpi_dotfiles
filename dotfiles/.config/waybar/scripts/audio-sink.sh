#!/bin/bash
# waybar custom 音频图标模块
# 每 2 秒由 waybar 调用，输出 JSON: {text, tooltip}

sink=$(pactl get-default-sink)
vol=$(pactl get-sink-volume "$sink" 2>/dev/null | grep -oP '\d+(?=%)' | head -1)
[ -z "$vol" ] && vol=0
muted=$(pactl get-sink-mute "$sink" 2>/dev/null | grep -oP '(?<=Mute: ).*')

if [ "$muted" = "yes" ]; then
    icon="󰝟"
elif echo "$sink" | grep -qi "bluez"; then
    icon="󰂯"
elif [ "$vol" -lt 33 ]; then
    icon="󰕿"
elif [ "$vol" -lt 66 ]; then
    icon="󰖀"
else
    icon="󰕾"
fi

if [ "$muted" = "yes" ]; then
    text="$icon"
    cls="muted"
else
    text="$vol% $icon"
    cls=""
fi

tooltip="扬声器 $vol%"
[ "$muted" = "yes" ] && tooltip="扬声器 已静音 ($vol%)"
if echo "$sink" | grep -qi "bluez"; then
    tooltip="蓝牙耳机 $vol%"
fi
tooltip="$tooltip\n---\n左键：打开面板\n右键：静音\n滚动：调节音量"

if [ -n "$cls" ]; then
    printf '{"text":"%s","tooltip":"%s","class":"%s"}' "$text" "$tooltip" "$cls"
else
    printf '{"text":"%s","tooltip":"%s"}' "$text" "$tooltip"
fi
