#!/bin/bash
# Fcitx5 输入法切换 OSD —— 切换输入法并显示当前输入法名称

# 切换输入法
fcitx5-remote -t

# 获取切换后的输入法
IME=$(fcitx5-remote -n 2>/dev/null)
case "$IME" in
    "rime")                     TEXT="中文" ICON="/usr/share/icons/hicolor/scalable/apps/fcitx-rime.svg" ;;
    "keyboard-us"|"keyboard-us-intl") TEXT="EN"  ICON="/usr/share/icons/Adwaita/scalable/devices/input-keyboard.svg" ;;
    *)                          TEXT="$IME" ICON="input-keyboard" ;;
esac

# 显示 OSD（--preempt 立即显示，覆盖排队）
awob send --preempt --icon "$ICON" --app "$TEXT" ime 1 100
