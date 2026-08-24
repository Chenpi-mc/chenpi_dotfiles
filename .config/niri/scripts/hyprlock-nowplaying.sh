#!/usr/bin/env bash
# hyprlock-nowplaying.sh — 显示当前正在播放的音乐和状态（供 hyprlock label 调用）
if command -v playerctl >/dev/null 2>&1; then
    song="$(playerctl metadata --format '{{title}} - {{artist}}' 2>/dev/null)"
    if [ -n "$song" ]; then
        status="$(playerctl status 2>/dev/null)"
        case "$status" in
            Playing) icon="⏸" ;;
            Paused)  icon="▶" ;;
            *)       icon="♪" ;;
        esac
        echo "$icon $song"
    fi
else
    exit 0
fi
