#!/bin/bash
# ==============================================================================
# install.sh — 在另一台 Arch 机器上恢复整套配置
# 骨架改写自 SHORiN-KiWATA/shorin-arch-setup 的 install.sh（AGPL-3.0）
#
#   ./install.sh            正常跑，已完成的模块会跳过
#   ./install.sh --yes      全程不问问题
#   ./install.sh --list     只列出会跑哪些模块
#   ./install.sh --force    忽略进度，全部重跑
#   ./install.sh --reset    清空进度记录
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
SRC="$SCRIPT_DIR/dotfiles"
STATE_FILE="$SCRIPT_DIR/.install_progress"
export VERIFY_LIST="/tmp/chenpi_install_verify.list"
export PREFLIGHT_REPORT="/tmp/chenpi-preflight.txt"

if [ ! -f "$SCRIPTS_DIR/00-utils.sh" ]; then
    echo "missing scripts/00-utils.sh" >&2
    exit 1
fi
source "$SCRIPTS_DIR/00-utils.sh"

FORCE=0
ASSUME_YES=0
LIST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --reset) rm -f "$STATE_FILE"; printf '%s\n' "$(t "进度记录已清空" "Progress cleared")"; exit 0 ;;
        --force|-f) FORCE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --list) LIST_ONLY=1 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \?//'; exit 0 ;;
    esac
done
[ "$FORCE" -eq 1 ] && rm -f "$STATE_FILE"

if [ ! -f "$SCRIPT_DIR/apps.conf" ]; then
    error "$(t "找不到 apps.conf" "apps.conf not found")"
    exit 1
fi
source "$SCRIPT_DIR/apps.conf"

if [ ! -d "$SRC" ]; then
    error "$(t "找不到 dotfiles 目录" "dotfiles directory missing")"
    exit 1
fi

touch "$STATE_FILE"
is_done() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { printf '%s\n' "$1" >> "$STATE_FILE"; }

in_list() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

MANDATORY_MODULES=(
    "00-btrfs-init.sh"
    "01a-base.sh"
    "02b-musthave.sh"
    "03c-snapshot-before-desktop.sh"
    "04-restore-config.sh"
    "05-verify.sh"
)

OPTIONAL_MENU=(
    "$(t "优化镜像源 reflector" "Optimize mirrors (reflector)")|01-mirrors.sh|0"
    "$(t "iwd 网络后端" "iwd wifi backend")|01c-nm-backend.sh|0"
    "$(t "双系统引导修复" "Dual-boot fix")|02c-dualboot-fix.sh|1"
    "$(t "显卡驱动自动检测" "GPU drivers (chwd)")|03b-gpu-driver.sh|1"
    "$(t "GRUB 主题" "GRUB theme")|07-grub-theme.sh|1"
    "$(t "按清单装应用" "Install apps from list")|99-apps.sh|1"
)

ORDERED_MODULES=(
    "00-btrfs-init.sh"
    "01-mirrors.sh"
    "01a-base.sh"
    "01c-nm-backend.sh"
    "02b-musthave.sh"
    "02c-dualboot-fix.sh"
    "03b-gpu-driver.sh"
    "03c-snapshot-before-desktop.sh"
    "04-restore-config.sh"
    "07-grub-theme.sh"
    "99-apps.sh"
    "05-verify.sh"
)

banner() {
    echo -e "   ${H_PURPLE}╭──────────────────────────────────────────────────────╮${NC}"
    echo -e "   ${H_PURPLE}│${NC}  ${BOLD}chenpi_dotfiles${NC}  ${DIM}Arch Linux + niri${NC}"
    echo -e "   ${H_PURPLE}╰──────────────────────────────────────────────────────╯${NC}"
    echo ""
}
show_banner() { clear 2>/dev/null || true; banner; }

ALLOW_PROMPT=0
[ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && ALLOW_PROMPT=1

select_optional_modules() {
    OPTIONAL_MODULES=()
    local item name script default

    if [ "$ALLOW_PROMPT" -eq 0 ]; then
        for item in "${OPTIONAL_MENU[@]}"; do
            IFS='|' read -r name script default <<< "$item"
            [ "$default" -eq 1 ] && OPTIONAL_MODULES+=("$script")
        done
        return 0
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        as_root pacman -S --needed --noconfirm fzf >/dev/null 2>&1 || true
    fi
    if ! command -v fzf >/dev/null 2>&1; then
        warn "$(t "没有 fzf，按默认选择" "no fzf, using defaults")"
        for item in "${OPTIONAL_MENU[@]}"; do
            IFS='|' read -r name script default <<< "$item"
            [ "$default" -eq 1 ] && OPTIONAL_MODULES+=("$script")
        done
        return 0
    fi

    local fzf_list=()
    for item in "${OPTIONAL_MENU[@]}"; do
        IFS='|' read -r name script default <<< "$item"
        if [ "$default" -eq 1 ]; then
            fzf_list+=("  ${name}\t${script}")
        else
            fzf_list+=("${name}\t${script}")
        fi
    done

    local selected
    selected=$(printf '%b\n' "${fzf_list[@]}" | fzf \
        --multi --delimiter='\t' --with-nth=1 \
        --layout=reverse --border=rounded \
        --border-label=" $(t "可选模块" "Optional modules") " --border-label-pos=5 \
        --color="marker:cyan,pointer:cyan,label:yellow" \
        --header=" $(t "[TAB] 勾选 | [CTRL-X] 全不选 | [ENTER] 确认" "[TAB] toggle | [CTRL-X] none | [ENTER] confirm") " \
        --pointer=">" --expect=ctrl-x,enter \
        --bind 'start:select-all,ctrl-a:select-all,ctrl-d:deselect-all,esc:abort' \
        --height=~20) || true

    if [ -n "${selected:-}" ]; then
        local key items
        key="$(head -n 1 <<< "$selected")"
        items="$(sed '1d' <<< "$selected")"
        if [ "$key" != "ctrl-x" ] && [ -n "$items" ]; then
            mapfile -t OPTIONAL_MODULES < <(echo "$items" | awk -F'\t' '{if ($2 != "") print $2}')
        fi
    fi
}

build_plan() {
    ALL_MODULES=("${MANDATORY_MODULES[@]}")
    [ ${#OPTIONAL_MODULES[@]} -gt 0 ] && ALL_MODULES+=("${OPTIONAL_MODULES[@]}")
    MODULES=()
    local m
    for m in "${ORDERED_MODULES[@]}"; do
        if in_list "$m" "${ALL_MODULES[@]}"; then MODULES+=("$m"); fi
    done
    TOTAL_STEPS=${#MODULES[@]}
}

list_modules() {
    section "$(t "这次会跑的模块" "Modules to run")" "$TOTAL_STEPS"
    local n=0 m
    for m in "${MODULES[@]}"; do
        n=$((n + 1))
        if is_done "$m"; then
            printf "   %2d. %-34s ${H_GREEN}%s${NC}\n" "$n" "$m" "$(t "已完成" "done")"
        else
            printf "   %2d. %s\n" "$n" "$m"
        fi
    done
    echo ""
}

show_banner
require_arch
detect_target_user
write_log "START" "install.sh | args: ${*:-none} | user: $(id -un) | cwd: $PWD"

section "$(t "系统检查" "System check")"
if ! bash "$SCRIPTS_DIR/00-preflight.sh"; then
    error "$(t "系统检查没通过" "preflight failed")"
    echo -e "   ${DIM}$(t "确认没问题可强行继续：CHENPI_IGNORE_PREFLIGHT=1 ./install.sh" "to override: CHENPI_IGNORE_PREFLIGHT=1 ./install.sh")${NC}"
    exit 1
fi

select_optional_modules
build_plan

show_banner
echo -e "   ${H_BLUE}●${NC} $(t "目标用户" "target user") : ${BOLD}${TARGET_USER}${NC} ${DIM}${TARGET_HOME}${NC}"
echo -e "   ${H_BLUE}●${NC} $(t "配置仓库" "repo")        : ${BOLD}${SCRIPT_DIR}${NC}"
echo -e "   ${H_BLUE}●${NC} $(t "待跑模块" "modules")     : ${TOTAL_STEPS}"
echo -e "   ${H_BLUE}●${NC} $(t "日志文件" "log")        : ${DIM}${LOG_FILE}${NC}"
echo ""

if [ "$LIST_ONLY" -eq 1 ]; then
    list_modules
    exit 0
fi

if [ "$ALLOW_PROMPT" -eq 1 ]; then
    echo -ne "   ${H_CYAN}$(t "确定开始安装？（会先备份现有配置）[Y/n] " "Start installation? (existing config gets backed up first) [Y/n] ")${NC}"
    read -t 60 -r go || go=""
    if [[ "${go:-}" =~ ^[[:space:]]*[Nn] ]]; then
        echo "   $(t "已取消" "cancelled")"
        exit 0
    fi
fi

setup_nopasswd
trap cleanup_nopasswd EXIT INT TERM

: > "$VERIFY_LIST"
CURRENT_STEP=0
FAILED_MODULES=()

for module in "${MODULES[@]}"; do
    CURRENT_STEP=$((CURRENT_STEP + 1))
    script_path="$SCRIPTS_DIR/$module"

    [ -f "$script_path" ] || { warn "$(t "模块不存在" "missing module"): $module"; continue; }

    if is_done "$module"; then
        printf "   ${H_GREEN}✔${NC} %s ${DIM}%s${NC}\n" "$module" "$(t "已完成，跳过" "already done")"
        continue
    fi

    section "$module" "$(t "模块" "module") $CURRENT_STEP/$TOTAL_STEPS"
    write_log "MODULE-START" "[$CURRENT_STEP/$TOTAL_STEPS] $module"
    started="$(date +%s)"

    bash "$script_path"
    exit_code=$?
    cost=$(( $(date +%s) - started ))

    if [ $exit_code -eq 0 ]; then
        mark_done "$module"
        write_log "MODULE-END" "$module ok ${cost}s"
        success "$module ${cost}s"
    elif [ $exit_code -eq 130 ]; then
        write_log "MODULE-END" "$module interrupted ${cost}s"
        warn "$(t "被中断，进度已保存" "interrupted, progress saved")"
        exit 130
    else
        write_log "MODULE-END" "$module failed exit=$exit_code ${cost}s"
        warn "$module $(t "失败" "failed") exit=$exit_code"
        FAILED_MODULES+=("$module")
    fi
done

section "$(t "收尾" "Cleanup")"
as_root pacman -Sc --noconfirm >/dev/null 2>&1 || true
if command -v grub-mkconfig >/dev/null 2>&1 && [ -f /boot/grub/grub.cfg ]; then
    as_root env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
fi

as_user mkdir -p "$TARGET_HOME/Documents" 2>/dev/null || true
[ -f "$LOG_FILE" ] && as_user cp "$LOG_FILE" "$TARGET_HOME/Documents/chenpi-install.log" 2>/dev/null || true
[ -f "$PREFLIGHT_REPORT" ] && as_user cp "$PREFLIGHT_REPORT" "$TARGET_HOME/Documents/$(t "装机前系统检查" "preflight-report").txt" 2>/dev/null || true

if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
    warn "$(t "失败的模块" "failed modules")（${#FAILED_MODULES[@]}）：${FAILED_MODULES[*]}"
    info_kv "$(t "重跑" "rerun")" "./install.sh" "$(t "会跳过已完成的" "skips finished modules")"
    error "$(t "有模块失败" "some modules failed")"
    exit 1
fi

mark_done "__全部完成__"
success "$(t "全部完成" "all done")"
info_kv "$(t "日志" "log")" "$TARGET_HOME/Documents/chenpi-install.log" ""
info_kv "$(t "重跑" "rerun")" "./install.sh" "$(t "会跳过已完成的" "skips finished modules")"
