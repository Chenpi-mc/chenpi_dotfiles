#!/bin/bash
# 轮询 fcitx5 输入法状态，切换时自动弹 OSD（实时检测，无需手动触发）
# 任何切换方式（快捷键/点击/脚本）都会触发

LAST=""

while true; do
    IME=$(fcitx5-remote -n 2>/dev/null)
    if [ -n "$IME" ] && [ "$IME" != "$LAST" ]; then
        if [ -n "$LAST" ]; then
            case "$IME" in
                "rime")                     TEXT="中文" ICON="/usr/share/icons/hicolor/scalable/apps/fcitx-rime.svg" ;;
                "keyboard-us"|"keyboard-us-intl") TEXT="EN"  ICON="/usr/share/icons/Adwaita/scalable/devices/input-keyboard.svg" ;;
                *)                          TEXT="$IME" ICON="input-keyboard" ;;
            esac
            awob send --preempt --icon "$ICON" --app "$TEXT" ime 1 100
        fi
        LAST="$IME"
    fi
    sleep 0.2
done
