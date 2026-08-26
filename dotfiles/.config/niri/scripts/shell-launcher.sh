#!/usr/bin/env bash
# Shell 启动台：fzf 选择并启动应用程序（替换 fuzzel）
set -euo pipefail

# 收集 desktop 文件（系统 + 用户）
mapfile -t DESKTOPS < <(find /usr/share/applications ~/.local/share/applications -name '*.desktop' 2>/dev/null | sort -u)

entries=()
for f in "${DESKTOPS[@]}"; do
    # 跳过 NoDisplay 的项
    if grep -q '^NoDisplay=true' "$f" 2>/dev/null; then continue; fi
    name=$(grep -m1 '^Name=' "$f" 2>/dev/null | cut -d= -f2-)
    [ -z "$name" ] && continue
    entries+=("$name | $f")
done

selected=$(printf '%s\n' "${entries[@]}" | fzf --prompt=' 启动应用: ' --height=60% --layout=reverse --border --tabstop=1)
[ -z "$selected" ] && exit 0

desktop="${selected##*| }"
[ -f "$desktop" ] || exit 0

# gtk-launch 按 desktop 文件名启动，自动处理 %U %f 等参数
gtk-launch "$(basename "$desktop" .desktop)" || {
    # 兜底：直接执行 Exec 字段
    exec_cmd=$(grep -m1 '^Exec=' "$desktop" | cut -d= -f2- | sed 's/%.//g')
    [ -n "$exec_cmd" ] && bash -c "$exec_cmd"
}
