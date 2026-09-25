#!/bin/bash
# ==============================================================================
# install.sh — 在另一台 Arch 机器上恢复整套配置
# 骨架改写自 SHORiN-KiWATA/shorin-arch-setup 的 install.sh（AGPL-3.0）
#
#   ./install.sh            交互菜单（1 开始安装 / 2 看系统信息 / 3 选可选模块）
#   ./install.sh --yes      不问任何问题，按默认直接装
#   ./install.sh --info     只打印系统信息
#   ./install.sh --list     只列出会跑哪些模块
#   ./install.sh --force    忽略进度记录，全部重跑
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
INFO_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --reset) rm -f "$STATE_FILE"; printf '%s\n' "$(t "进度记录已清空" "Progress cleared")"; exit 0 ;;
        --force|-f) FORCE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --list) LIST_ONLY=1 ;;
        --info) INFO_ONLY=1 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
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

ALLOW_PROMPT=0
[ "$ASSUME_YES" -eq 0 ] && [ -t 0 ] && ALLOW_PROMPT=1

banner() {
    echo -e "   ${BOLD}chenpi_dotfiles${NC} ${DIM}· Arch Linux + niri${NC}"
}

use_default_modules() {
    OPTIONAL_MODULES=()
    local item name script default
    for item in "${OPTIONAL_MENU[@]}"; do
        IFS='|' read -r name script default <<< "$item"
        [ "$default" -eq 1 ] && OPTIONAL_MODULES+=("$script")
    done
}

pick_optional_modules() {
    if ! command -v fzf >/dev/null 2>&1; then
        as_root pacman -S --needed --noconfirm fzf >/dev/null 2>&1 || true
    fi
    if ! command -v fzf >/dev/null 2>&1; then
        warn "$(t "没有 fzf，用默认模块" "no fzf, using defaults")"
        use_default_modules
        return 0
    fi

    local fzf_list=() item name script default
    for item in "${OPTIONAL_MENU[@]}"; do
        IFS='|' read -r name script default <<< "$item"
        if in_list "$script" "${OPTIONAL_MODULES[@]}"; then
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

    [ -z "${selected:-}" ] && return 0

    local key items
    key="$(head -n 1 <<< "$selected")"
    items="$(sed '1d' <<< "$selected")"
    if [ "$key" = "ctrl-x" ]; then
        OPTIONAL_MODULES=()
    elif [ -n "$items" ]; then
        mapfile -t OPTIONAL_MODULES < <(echo "$items" | awk -F'\t' '{if ($2 != "") print $2}')
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
    section "$(t "会跑的模块" "Modules")" "$TOTAL_STEPS"
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

run_preflight() {
    local mode="${1:-quiet}"
    if [ "$mode" = "quiet" ]; then
        PREFLIGHT_QUIET=1 bash "$SCRIPTS_DIR/00-preflight.sh"
    else
        bash "$SCRIPTS_DIR/00-preflight.sh"
    fi
}

# ------------------------------- 安装 -------------------------------
do_install() {
    build_plan

    section "$(t "系统检查" "System check")"
    if ! run_preflight quiet; then
        error "$(t "系统检查没通过" "preflight failed")"
        echo -e "   ${DIM}$(t "确认没问题可强行继续：CHENPI_IGNORE_PREFLIGHT=1 ./install.sh" "override: CHENPI_IGNORE_PREFLIGHT=1 ./install.sh")${NC}"
        exit 1
    fi

    setup_nopasswd
    trap cleanup_nopasswd EXIT INT TERM

    : > "$VERIFY_LIST"
    local CURRENT_STEP=0 module script_path exit_code started cost
    FAILED_MODULES=()
    write_log "START" "install.sh | user: $(id -un) | modules: ${#MODULES[@]}"

    for module in "${MODULES[@]}"; do
        CURRENT_STEP=$((CURRENT_STEP + 1))
        script_path="$SCRIPTS_DIR/$module"

        if [ ! -f "$script_path" ]; then
            warn "$(t "模块不存在" "missing module"): $module"
            continue
        fi

        if is_done "$module"; then
            printf "   ${H_GREEN}${TICK}${NC} %s ${DIM}%s${NC}\n" "$module" "$(t "已完成" "done")"
            continue
        fi

        section "$module" "$CURRENT_STEP/$TOTAL_STEPS"
        write_log "MODULE-START" "[$CURRENT_STEP/$TOTAL_STEPS] $module"
        started="$(date +%s)"

        bash "$script_path"
        exit_code=$?
        cost=$(( $(date +%s) - started ))

        if [ $exit_code -eq 0 ]; then
            mark_done "$module"
            write_log "MODULE-END" "$module ok ${cost}s"
        elif [ $exit_code -eq 130 ]; then
            write_log "MODULE-END" "$module interrupted"
            warn "$(t "被中断，进度已保存" "interrupted, progress saved")"
            exit 130
        else
            write_log "MODULE-END" "$module failed exit=$exit_code"
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

    echo ""
    if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
        warn "$(t "失败" "failed")（${#FAILED_MODULES[@]}）：${FAILED_MODULES[*]}"
        error "$(t "有模块失败，修好重跑" "some modules failed; fix and rerun")"
        exit 1
    fi
    mark_done "__全部完成__"
    success "$(t "全部完成" "all done")"
    echo -e "   ${DIM}$(t "日志" "log"): $TARGET_HOME/Documents/chenpi-install.log${NC}"
}

# ------------------------------- 菜单 -------------------------------
show_menu() {
    clear 2>/dev/null || true
    banner
    echo ""
    echo -e "   $(t "用户" "user")   ${BOLD}${TARGET_USER}${NC} ${DIM}${TARGET_HOME}${NC}"
    echo -e "   $(t "仓库" "repo")   ${DIM}${SCRIPT_DIR}${NC}"
    echo -e "   $(t "模块" "modules")  ${#OPTIONAL_MODULES[@]} $(t "个可选" "optional") + ${#MANDATORY_MODULES[@]} $(t "个必装" "required")"
    echo ""
    echo -e "   ${H_CYAN}1)${NC} $(t "开始安装" "Start install")"
    echo -e "   ${H_CYAN}2)${NC} $(t "查看系统信息" "System info")"
    echo -e "   ${H_CYAN}3)${NC} $(t "选择可选模块" "Pick optional modules")"
    echo -e "   ${H_CYAN}4)${NC} $(t "退出" "Quit")"
    echo ""
    echo -ne "   $(t "选择" "choice") [1]: "
}

main_menu() {
    local choice
    while true; do
        show_menu
        read -t 300 -r choice || choice=""
        case "${choice:-1}" in
            1) do_install; return ;;
            2) section "$(t "系统信息" "System info")"; run_preflight full; echo ""; echo -ne "   ${DIM}$(t "回车返回" "enter to return")${NC}"; read -r _ || true ;;
            3) pick_optional_modules ;;
            4|q|Q) exit 0 ;;
            *) ;;
        esac
        if [ "${choice}" = "2" ] || [ "${choice}" = "3" ]; then :; fi
    done
}

# ------------------------------- 主流程 -------------------------------
require_arch
detect_target_user
use_default_modules
build_plan

if [ "$LIST_ONLY" -eq 1 ]; then
    banner
    list_modules
    exit 0
fi

if [ "$INFO_ONLY" -eq 1 ]; then
    banner
    section "$(t "系统信息" "System info")"
    run_preflight full
    exit 0
fi

if [ "$ALLOW_PROMPT" -eq 1 ]; then
    main_menu
else
    do_install
fi
