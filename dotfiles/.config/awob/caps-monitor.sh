#!/bin/bash
# 轮询 CapsLock led 状态变化并弹 OSD（sysfs inotify 不可靠，改用轮询）

LED="/sys/class/leds/input3::capslock/brightness"

if [ ! -f "$LED" ]; then
    echo "capslock led 不存在: $LED" >&2
    exit 1
fi

LAST=$(cat "$LED" 2>/dev/null)

while true; do
    STATE=$(cat "$LED" 2>/dev/null)
    if [ -n "$STATE" ] && [ "$STATE" != "$LAST" ]; then
        if [ "$STATE" = "0" ]; then
            awob send --preempt --icon "/usr/share/icons/Papirus/16x16/symbolic/status/capslock-disabled-symbolic.svg" --app "小写" caps 0 100
        else
            awob send --preempt --icon "/usr/share/icons/Papirus/16x16/symbolic/status/capslock-enabled-symbolic.svg" --app "大写" caps 100 100
        fi
        LAST="$STATE"
    fi
    sleep 0.2
done
