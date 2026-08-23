#!/bin/bash
# waybar media play/pause 图标（实时跟随播放状态）
status=$(playerctl status 2>/dev/null)
if [[ "$status" == "Playing" ]]; then
    echo "󰏤"
elif [[ "$status" == "Paused" ]]; then
    echo "󰐊"
else
    echo "󰐊"
fi
