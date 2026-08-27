#!/bin/bash
# 监听 CapsLock 状态变化并弹 OSD（inotify 事件驱动）

LED="/sys/class/leds/input3::capslock/brightness"

if [ ! -f "$LED" ]; then
    echo "capslock led 不存在: $LED" >&2
    exit 1
fi

LAST=$(cat "$LED" 2>/dev/null)

while true; do
    inotifywait -q -e modify "$LED" >/dev/null 2>&1
    STATE=$(cat "$LED" 2>/dev/null)
    if [ -n "$STATE" ] && [ "$STATE" != "$LAST" ]; then
        if [ "$STATE" = "0" ]; then
            awob send --preempt --icon "input-caps-lock" --app "小写" caps 0 100
        else
            awob send --preempt --icon "input-caps-lock" --app "大写" caps 100 100
        fi
        LAST="$STATE"
    fi
done
