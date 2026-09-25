#!/bin/bash
# ==============================================================================
# install.sh — 在另一台 Arch 机器上恢复整套配置
# 骨架改写自 SHORiN-KiWATA/shorin-arch-setup 的 install.sh（AGPL-3.0）
#
# 用法：
#   ./install.sh              正常跑（已完成的模块自动跳过）
#   ./install.sh --force      忽略进度记录，全部重跑
#   ./install.sh --reset      只清空进度记录，不安装
#   ./install.sh --list       只列出这次会跑哪些模块
#   ./install.sh --yes        不问问题，全部按默认走（无人值守）
# ==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
SRC="$SCRIPT_DIR/dotfiles"
STATE_FILE="$SCRIPT_DIR/.install_progress"
export VERIFY_LIST="/tmp/chenpi_install_verify.list"

# ------------------------------- 参数 -------------------------------
FORCE=0
ASSUME_YES=0
LIST_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --reset) rm -f "$STATE_FILE"; printf '进度记录已清空，下次从头跑\n'; exit 0 ;;
        --force|-f) FORCE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --list) LIST_ONLY=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    esac
done

# ------------------------------- 载入函数库 -------------------------------
if [ ! -f "$SCRIPTS_DIR/00-utils.sh" ]; then
    echo "错误：找不到 scripts/00-utils.sh" >&2
    exit 1
fi
source "$SCRIPTS_DIR/00-utils.sh"

if [ ! -f "$SCRIPT_DIR/apps.conf" ]; then
    error "找不到 apps.conf（配置清单）"
    exit 1
fi
source "$SCRIPT_DIR/apps.conf"

if [ ! -d "$SRC" ]; then
    error "找不到 $SRC —— 先把仓库 clone 好再跑"
    exit 1
fi

if [ "$FORCE" -eq 1 ]; then
    rm -f "$STATE_FILE"
    printf '忽略进度记录，本次全部重跑\n'
fi

# ------------------------------- 进度记录 -------------------------------
touch "$STATE_FILE"
write_log "START" "install.sh 启动｜参数：${*:-无}｜用户：$(id -un)｜工作目录：$PWD"
write_log "START" "仓库：$SCRIPT_DIR"
is_done() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { printf '%s\n' "$1" >> "$STATE_FILE"; }

# ------------------------------- 横幅 -------------------------------
banner() {
    echo -e "   ${H_PURPLE}╭──────────────────────────────────────────────────────╮${NC}"
    echo -e "   ${H_PURPLE}│${NC}  ${BOLD}chenpi_dotfiles${NC}  ${DIM}装机脚本${NC}"
    echo -e "   ${H_PURPLE}│${NC}  ${DIM}Arch Linux + niri｜断点续传｜自动备份｜装后对账${NC}"
    echo -e "   ${H_PURPLE}╰──────────────────────────────────────────────────────╯${NC}"
    echo ""
}

show_banner() { clear 2>/dev/null || true; banner; }

# ------------------------------- 模块清单 -------------------------------
MANDATORY_MODULES=(
    "00-preflight.sh"
    "00-btrfs-init.sh"
    "01a-base.sh"
    "02b-musthave.sh"
    "03c-snapshot-before-desktop.sh"
    "04-restore-config.sh"
    "05-verify.sh"
)

# 可选模块：名字|脚本|默认选不选（1=默认选）
OPTIONAL_MENU=(
    "优化镜像源（reflector，国内加速）|01-mirrors.sh|0"
    "iwd 网络后端（替代 wpa_supplicant）|01c-nm-backend.sh|0"
    "双系统引导修复（找 Windows）|02c-dualboot-fix.sh|1"
    "显卡驱动自动检测（chwd）|03b-gpu-driver.sh|1"
    "GRUB 主题|07-grub-theme.sh|1"
    "按清单装应用|99-apps.sh|1"
)

# ------------------------------- 模块顺序表 -------------------------------
# 模块按这里的先后执行，再按“必装 / 用户选中”过滤。
# 对账（05-verify）固定放最后，否则它跑在装应用之前，等于没对账。
ORDERED_MODULES=(
    "00-preflight.sh"
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

in_list() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# ------------------------------- 汇总与确认 -------------------------------
select_optional_modules() {
    OPTIONAL_MODULES=()
    local item name script default

    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
        for item in "${OPTIONAL_MENU[@]}"; do
            IFS='|' read -r name script default <<< "$item"
            [ "$default" -eq 1 ] && OPTIONAL_MODULES+=("$script")
        done
        log "非交互模式：可选模块按默认选择（${#OPTIONAL_MODULES[@]} 个）"
        return 0
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        log "没装 fzf，装一下用来做选择菜单"
        as_root pacman -S --noconfirm --needed fzf >/dev/null 2>&1 || true
    fi

    if ! command -v fzf >/dev/null 2>&1; then
        warn "fzf 装不上，按默认选择走"
        for item in "${OPTIONAL_MENU[@]}"; do
            IFS='|' read -r name script default <<< "$item"
            [ "$default" -eq 1 ] && OPTIONAL_MODULES+=("$script")
        done
        return 0
    fi

    local fzf_list=() pre_sel=""
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
        --border-label=" 选择可选模块 " --border-label-pos=5 \
        --color="marker:cyan,pointer:cyan,label:yellow" \
        --header=" [TAB] 勾选 | [CTRL-X] 全不选 | [ENTER] 确认 " \
        --pointer=">" --expect=ctrl-x,enter \
        --bind 'start:select-all,ctrl-a:select-all,ctrl-d:deselect-all,esc:abort' \
        --height=~20)

    local fzf_status=$?
    if [ $fzf_status -eq 130 ]; then
        echo ""
        warn "用户取消了安装"
        exit 130
    fi

    if [ -n "$selected" ]; then
        local key items
        key="$(head -n 1 <<< "$selected")"
        items="$(sed '1d' <<< "$selected")"
        if [ "$key" != "ctrl-x" ] && [ -n "$items" ]; then
            mapfile -t OPTIONAL_MODULES < <(echo "$items" | awk -F'\t' '{if ($2 != "") print $2}')
        fi
    fi
    log "选中的可选模块：${#OPTIONAL_MODULES[@]} 个"
}

# ------------------------------- 汇总与确认 -------------------------------
sys_dashboard() {
    echo ""
    echo -e "   ${H_BLUE}●${NC} 目标用户   : ${BOLD}${TARGET_USER}${NC} ${DIM}(${TARGET_HOME})${NC}"
    echo -e "   ${H_BLUE}●${NC} 配置仓库   : ${BOLD}${SCRIPT_DIR}${NC}"
    if is_done "__全部完成__"; then
        echo -e "   ${H_BLUE}●${NC} 进度       : ${H_GREEN}上次已跑完${NC}"
    else
        local done_n=0 m
        for m in "${MODULES[@]}"; do is_done "$m" && done_n=$((done_n + 1)); done
        echo -e "   ${H_BLUE}●${NC} 进度       : 已完成 ${done_n}/${#MODULES[@]} 个模块"
    fi
    echo -e "   ${H_BLUE}●${NC} 日志文件   : ${DIM}${LOG_FILE}${NC}"
    echo ""
}

# ------------------------------- 主流程 -------------------------------
show_banner
section "环境检查" "确认是 Arch、找到仓库和目标用户"
require_arch
detect_target_user
success "目标用户 $TARGET_USER（$TARGET_HOME）"
success "配置仓库 $SCRIPT_DIR"

# 安装期间免密，退出时务必删掉规则（trap 兜住 Ctrl+C 和报错退出）
if [ "$ASSUME_YES" -eq 1 ] || [ -t 0 ]; then
    section "临时免密" "省得每一步都问密码"
    setup_nopasswd
    trap cleanup_nopasswd EXIT INT TERM
fi

select_optional_modules

# 按 ORDERED_MODULES 的顺序过滤出这次要跑的：必装 + 用户选中的可选
ALL_MODULES=("${MANDATORY_MODULES[@]}")
if [ ${#OPTIONAL_MODULES[@]} -gt 0 ]; then
    ALL_MODULES+=("${OPTIONAL_MODULES[@]}")
fi
MODULES=()
for _m in "${ORDERED_MODULES[@]}"; do
    if in_list "$_m" "${ALL_MODULES[@]}"; then
        MODULES+=("$_m")
    fi
done
TOTAL_STEPS=${#MODULES[@]}

show_banner
sys_dashboard

if [ "$LIST_ONLY" -eq 1 ]; then
    section "这次会跑的模块" "$TOTAL_STEPS 个"
    n=0
    for m in "${MODULES[@]}"; do
        n=$((n + 1))
        if is_done "$m"; then
            printf "   %2d. %-38s ${H_GREEN}已完成${NC}\n" "$n" "$m"
        else
            printf "   %2d. %s\n" "$n" "$m"
        fi
    done
    echo ""
    exit 0
fi

if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
    echo -ne "   ${H_CYAN}开始安装？先自动备份现有配置。[Y/n] ${NC}"
    read -t 30 -r go
    if [[ "${go:-}" =~ ^[[:space:]]*[Nn] ]]; then
        echo "   已取消"
        exit 0
    fi
fi

# 清空上次的对账清单
: > "$VERIFY_LIST"

CURRENT_STEP=0
FAILED_MODULES=()

for module in "${MODULES[@]}"; do
    CURRENT_STEP=$((CURRENT_STEP + 1))
    script_path="$SCRIPTS_DIR/$module"

    if [ ! -f "$script_path" ]; then
        warn "模块不存在，跳过：$module"
        continue
    fi

    if is_done "$module"; then
        echo -e "   ${H_GREEN}✔${NC} ${BOLD}$module${NC} ${DIM}（已完成，跳过）${NC}"
        continue
    fi

    section "模块 $CURRENT_STEP/$TOTAL_STEPS" "$module"
    echo ""

    write_log "MODULE-START" "[$CURRENT_STEP/$TOTAL_STEPS] $module"
    module_start_ts="$(date +%s)"
    bash "$script_path"
    exit_code=$?
    module_cost=$(( $(date +%s) - module_start_ts ))

    if [ $exit_code -eq 0 ]; then
        mark_done "$module"
        write_log "MODULE-END" "$module 成功｜耗时 ${module_cost}s"
        success "模块 $module 完成（耗时 ${module_cost}s）"
    elif [ $exit_code -eq 130 ]; then
        echo ""
        write_log "MODULE-END" "$module 被中断｜耗时 ${module_cost}s"
        warn "被用户中断（Ctrl+C）。进度已保存，重跑会接着来。"
        exit 130
    else
        write_log "MODULE-END" "$module 失败，退出码 $exit_code｜耗时 ${module_cost}s"
        warn "模块 $module 失败（退出码 $exit_code），记录后继续"
        FAILED_MODULES+=("$module")
        # 系统检查没过就别往下装了，先把问题解决
        if [ "$module" = "00-preflight.sh" ]; then
            error "系统检查没通过。按上面的提示解决后重跑，已完成的模块会自动跳过"
            exit 1
        fi
    fi
done

# ------------------------------- 收尾 -------------------------------
section "收尾" "清缓存、重建 GRUB、汇总"

log "清理 pacman 缓存（旧版本包）"
exe as_root pacman -Sc --noconfirm || true

if command -v grub-mkconfig >/dev/null 2>&1 && [ -f /boot/grub/grub.cfg ]; then
    log "重建 GRUB 配置"
    exe as_root env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg || true
fi

# 把日志存一份到用户文档目录，方便事后排查
if [ -f "$LOG_FILE" ]; then
    as_user mkdir -p "$TARGET_HOME/Documents" 2>/dev/null || true
    as_user cp "$LOG_FILE" "$TARGET_HOME/Documents/chenpi-install.log" 2>/dev/null || true
fi

# 装机前的系统检查报告也存一份，以后回头看这台机器当时什么状况
if [ -f /tmp/chenpi-preflight.txt ]; then
    as_user mkdir -p "$TARGET_HOME/Documents" 2>/dev/null || true
    as_user cp /tmp/chenpi-preflight.txt "$TARGET_HOME/Documents/装机前系统检查.txt" 2>/dev/null || true
fi

section "完成" "汇总"

if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
    warn "这些模块失败了（${#FAILED_MODULES[@]} 个）："
    printf '       %s\n' "${FAILED_MODULES[@]}"
    warn "修好之后重跑本脚本，会直接跳过已完成的模块"
else
    success "所有模块执行完毕"
    mark_done "__全部完成__"
fi

info_kv "日志" "$LOG_FILE" "也存了一份到 ~/Documents"
info_kv "重跑" "./install.sh" "会自动跳过已完成的模块"
info_kv "全部重来" "./install.sh --force" ""
info_kv "清空进度" "./install.sh --reset" ""

echo ""
if [ ${#FAILED_MODULES[@]} -gt 0 ]; then
    error "有模块失败，看上面的清单和日志再补"
    exit 1
fi
success "全部完成。如果装了新内核，建议重启一下。"
