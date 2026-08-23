#!/usr/bin/env bash
# 监听音频设备变化：蓝牙耳机出现时自动设为默认输出，断开时回退内置声卡
# 用 pactl 而非 wpctl：wpctl 走 WirePlumber D-Bus 接口，不广播 PulseAudio 事件，
# waybar 监听的是 PulseAudio 协议，收不到变化通知所以图标卡住。
# pactl set-default-sink 是 PulseAudio 原生接口，任何切换都会广播 change 事件。

set_default() {
  bluez_sink=$(pactl list sinks short | awk '/bluez_output/{print $2; exit}')
  if [ -n "$bluez_sink" ]; then
    pactl set-default-sink "$bluez_sink"
  else
    builtin_sink=$(pactl list sinks short | awk '/analog-stereo/{print $2; exit}')
    [ -n "$builtin_sink" ] && pactl set-default-sink "$builtin_sink"
  fi
}

# 启动时先处理已连接的设备
set_default

pactl subscribe | while read -r line; do
  case "$line" in
    *"sink"*)
      sleep 1
      set_default
      # 蓝牙 sink 消失后强制再触发一次事件（no-op 切换也会广播），
      # 确保 waybar 刷新回内置图标
      pactl set-default-sink "$(pactl get-default-sink)" 2>/dev/null
      ;;
  esac
done
