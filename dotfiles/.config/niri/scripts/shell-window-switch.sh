#!/usr/bin/env bash
# Shell 窗口切换器：fzf 选择窗口并聚焦（替换 fuzzel 窗口切换）
set -euo pipefail

windows=$(niri msg -j windows)
[ -z "$windows" ] && exit 0

# 格式: id<TAB>标题 [app_id]
choices=$(echo "$windows" | jq -r '.[] | "\(.id)\t\(.title // "(无标题)") [\(.app_id // "?")]"')

selected=$(echo "$choices" | fzf --prompt=' 切换窗口: ' --height=60% --layout=reverse --border --with-nth=2..)
[ -z "$selected" ] && exit 0

wid=$(echo "$selected" | cut -f1)
niri msg action focus-window --id "$wid"
