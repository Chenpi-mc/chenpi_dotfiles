#!/bin/bash
# ==============================================================================
# 00-utils.sh — 公共函数库，所有模块都 source 它
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/00-utils.sh（AGPL-3.0）
#
# 相对原版：不强制 root；支持中英双语输出；去掉了绑定他自己源的部分。
# ==============================================================================

# ------------------------------- 语言 -------------------------------
# locale 是中文就中文，否则英文（TTY 一般显示不了中文）。
# 想强制指定：CHENPI_LANG=zh 或 CHENPI_LANG=en
if [ -z "${CHENPI_LANG:-}" ]; then
    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
        zh*) CHENPI_LANG=zh ;;
        *)   CHENPI_LANG=en ;;
    esac
fi
export CHENPI_LANG

# 双语取词：t "中文" "English"
t() {
    if [ "$CHENPI_LANG" = "zh" ]; then
        printf '%s' "$1"
    else
        printf '%s' "${2:-$1}"
    fi
}

# ------------------------------- 颜色与符号 -------------------------------
export NC='\033[0m'
export BOLD='\033[1m'
export DIM='\033[2m'
export H_RED='\033[1;31m'
export H_GREEN='\033[1;32m'
export H_YELLOW='\033[1;33m'
export H_BLUE='\033[1;34m'
export H_PURPLE='\033[1;35m'
export H_CYAN='\033[1;36m'
export H_WHITE='\033[1;37m'
export H_GRAY='\033[1;90m'
export TICK="${H_GREEN}✔${NC}"
export CROSS="${H_RED}✘${NC}"
export MARK_WARN="${H_YELLOW}⚠${NC}"
export ARROW="${H_CYAN}➜${NC}"

# ------------------------------- 日志文件 -------------------------------
export LOG_FILE="${LOG_FILE:-/tmp/chenpi-install.log}"

write_log() {
    local clean
    clean="$(echo -e "${2:-}" | sed 's/\x1b\[[0-9;]*m//g')"
    # 日志写不进去（磁盘满、/tmp 只读）不该把脚本带崩，静默忽略
    printf '[%s] [%s] %s\n' "$(date '+%H:%M:%S')" "$1" "$clean" >> "$LOG_FILE" 2>/dev/null || true
}

# ------------------------------- 输出函数 -------------------------------
hr() { printf "${H_GRAY}%*s${NC}\n" "${COLUMNS:-80}" '' | tr ' ' '─'; }

section() {
    local title="$1" subtitle="${2:-}"
    echo ""
    echo -e "${H_PURPLE}╭──────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}${H_WHITE}${title}${NC}"
    if [ -n "$subtitle" ]; then
        echo -e "${H_PURPLE}│${NC} ${H_CYAN}${subtitle}${NC}"
    fi
    echo -e "${H_PURPLE}╰──────────────────────────────────────────────────────────────────────────────╯${NC}"
    write_log "SECTION" "$title — $subtitle"
}

info_kv() {
    printf "   ${H_BLUE}●${NC} %-18s: ${BOLD}%s${NC} ${DIM}%s${NC}\n" "$1" "$2" "${3:-}"
    write_log "INFO" "$1=$2"
}

log() {
    echo -e "   $ARROW $1"
    write_log "LOG" "$1"
}

success() {
    echo -e "   $TICK ${H_GREEN}$1${NC}"
    write_log "OK" "$1"
}

warn() {
    echo -e "   $MARK_WARN ${H_YELLOW}$1${NC}"
    write_log "WARN" "$1"
}

error() {
    echo ""
    echo -e "${H_RED}   ${CROSS} $1${NC}"
    echo ""
    write_log "ERROR" "$1"
}

# ------------------------------- 命令执行器 -------------------------------
# 带边框显示正在做什么，同时写日志，返回原命令的退出码
exe() {
    echo -e "   ${H_GRAY}┌──[ ${H_PURPLE}执行${H_GRAY} ]───────────────────────────────────────────────${NC}"
    echo -e "   ${H_GRAY}│${NC} ${H_CYAN}\$${NC} ${BOLD}$*${NC}"
    write_log "EXEC" "$*"
    "$@"
    local status=$?
    if [ $status -eq 0 ]; then
        echo -e "   ${H_GRAY}└─────────────────────────────────────────────${H_GREEN}成功${H_GRAY} ─┘${NC}"
    else
        echo -e "   ${H_GRAY}└─────────────────────────────────────────────${H_RED}失败${H_GRAY} ─┘${NC}"
        write_log "FAIL" "exit $status: $*"
    fi
    return $status
}

exe_silent() { "$@" >/dev/null 2>&1; }

# ------------------------------- 身份与权限 -------------------------------
# 以 root 执行（本来就是 root 就直接跑，否则走 sudo）
as_root() {
    if [ "${RUN_AS_ROOT:-0}" -eq 1 ]; then "$@"; else sudo "$@"; fi
}

# 只读探测专用：拿不到权限就静默失败，不弹密码
as_root_quiet() {
    if [ "${RUN_AS_ROOT:-0}" -eq 1 ]; then "$@"; else sudo -n "$@" 2>/dev/null; fi
}

# 以目标用户执行（root 跑时用 runuser 切回去，普通用户跑时就是自己）
as_user() {
    if [ "${RUN_AS_ROOT:-0}" -eq 1 ]; then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
        "$@"
    fi
}

# root 跑的情况下把属主改回目标用户
fix_owner() {
    [ "${RUN_AS_ROOT:-0}" -eq 1 ] || return 0
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then chown -R "$TARGET_USER:" "$p" 2>/dev/null || true; fi
    done
}

require_arch() {
    if ! command -v pacman >/dev/null 2>&1; then
        error "$(t "这不是 Arch Linux（找不到 pacman）" "not Arch Linux (pacman not found)")"
        exit 1
    fi
}

# ------------------------------- 目标用户识别 -------------------------------
# 结果写进全局：RUN_AS_ROOT / TARGET_USER / TARGET_HOME
detect_target_user() {
    if [ "$(id -u)" -eq 0 ]; then
        RUN_AS_ROOT=1
        TARGET_USER="${SUDO_USER:-}"
    else
        RUN_AS_ROOT=0
        TARGET_USER="$(id -un)"
    fi

    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        local human_users=()
        mapfile -t human_users < <(awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd)
        if [ ${#human_users[@]} -eq 0 ]; then
            error "$(t "系统里没有普通用户，先用普通用户跑或先建一个" "no regular user found; create one first")"
            exit 1
        fi

        local default_user
        default_user="$(awk -F: '$3 == 1000 {print $1}' /etc/passwd | head -n 1)"
        [ -z "$default_user" ] && default_user="${human_users[0]}"

        if [ -t 0 ] && [ ${#human_users[@]} -gt 1 ]; then
            echo -e "   ${H_YELLOW}$(t "检测到多个普通用户，选一个作为配置目标：" "multiple users found, pick the target:")${NC}"
            local i
            for i in "${!human_users[@]}"; do
                local mark=""
                if [ "${human_users[$i]}" = "$default_user" ]; then mark=" ${H_CYAN}$(t "(默认)" "(default)")${NC}"; fi
                echo -e "       [$((i + 1))] ${human_users[$i]}${mark}"
            done
            echo -ne "   ${H_CYAN}$(t "输入序号（回车用默认，20 秒超时）：" "pick a number (enter = default, 20s timeout): ")${NC}"
            local idx
            if read -t 20 -r idx && [ -n "$idx" ] && [[ "$idx" =~ ^[0-9]+$ ]] \
               && [ "$idx" -ge 1 ] && [ "$idx" -le "${#human_users[@]}" ]; then
                TARGET_USER="${human_users[$((idx - 1))]}"
            else
                TARGET_USER="$default_user"
                echo ""
            fi
        else
            TARGET_USER="$default_user"
        fi
    fi

    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
        error "$(t "找不到 $TARGET_USER 的家目录" "no home directory for $TARGET_USER")"
        exit 1
    fi

    export RUN_AS_ROOT TARGET_USER TARGET_HOME
}

# ------------------------------- 文件操作 -------------------------------
# 强行覆盖：目标里已有的同名目录整个删掉再拷，避免留旧文件
force_copy() {
    local src="$1" target_dir="$2"
    if [ -z "$src" ] || [ -z "$target_dir" ]; then
        warn "$(t "force_copy 参数不完整" "force_copy: missing arguments")"
        return 1
    fi
    as_user mkdir -p "$target_dir"
    if [ -d "$src" ]; then
        as_user rm -rf "${target_dir:?}/$(basename "$src")"
    fi
    as_user cp -rf "$src" "$target_dir"
}

# ------------------------------- 显示管理器 -------------------------------
KNOWN_DMS=(sddm gdm lightdm lxdm ly lemurs plasmalogin plasma-login-manager greetd)

# 检测已有 DM，结果写进 DM_FOUND / DM_ENABLED，并设置 SKIP_DM
check_dm_conflict() {
    DM_FOUND=""
    DM_ENABLED=""
    local dm
    for dm in "${KNOWN_DMS[@]}"; do
        if pacman -Qq "$dm" >/dev/null 2>&1; then
            DM_FOUND="${DM_FOUND:+$DM_FOUND }$dm"
            if systemctl is-enabled "$dm" >/dev/null 2>&1; then
                DM_ENABLED="${DM_ENABLED:+$DM_ENABLED }$dm"
            fi
        fi
    done

    if [ -n "$DM_FOUND" ]; then
        info_kv "$(t "已有显示管理器" "display managers")" "$DM_FOUND"
        [ -n "$DM_ENABLED" ] && info_kv "$(t "已启用" "enabled")" "$DM_ENABLED"
        export SKIP_DM=true
    else
        info_kv "$(t "显示管理器" "display manager")" "$(t "无" "none")"
        export SKIP_DM=false
    fi
}

# ------------------------------- AUR 助手 -------------------------------
# 顺序很重要：先看已配置的源（archlinuxcn 这类社区源自带 yay/paru），
# 源里真没有才从 AUR 自举。makepkg 不能以 root 跑，所以自举时要切回用户。
AUR_HELPER=""
ensure_aur_helper() {
    if command -v yay >/dev/null 2>&1; then
        AUR_HELPER="yay"
    elif command -v paru >/dev/null 2>&1; then
        AUR_HELPER="paru"
    fi
    if [ -n "$AUR_HELPER" ]; then
        success "$(t "AUR 助手已存在：$AUR_HELPER" "AUR helper found: $AUR_HELPER")"
        export AUR_HELPER
        return 0
    fi

    local from_repo=() h
    for h in yay paru; do
        if pacman -Si "$h" >/dev/null 2>&1; then from_repo+=("$h"); fi
    done

    if [ ${#from_repo[@]} -gt 0 ]; then
        log "$(t "从已配置的源安装：${from_repo[*]}" "installing from configured repos: ${from_repo[*]}")"
        exe as_root pacman -S --needed --noconfirm "${from_repo[@]}"
        if command -v yay >/dev/null 2>&1; then AUR_HELPER="yay"; elif command -v paru >/dev/null 2>&1; then AUR_HELPER="paru"; fi
        if [ -n "$AUR_HELPER" ]; then
            success "$(t "AUR 助手装好了：$AUR_HELPER" "AUR helper installed: $AUR_HELPER")"
            export AUR_HELPER
            return 0
        fi
        warn "$(t "源里装了但命令找不到，改试 AUR 自举" "installed from repo but command missing; trying AUR bootstrap")"
    fi

    log "$(t "源里没有 yay / paru，从 AUR 自举 yay-bin" "no yay/paru in repos; bootstrapping yay-bin from AUR")"
    exe as_root pacman -S --needed --noconfirm base-devel git || true

    local tmp
    tmp="$(mktemp -d)"
    if ! git clone --depth=1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"; then
        warn "$(t "克隆失败，AUR 包这次跳过" "clone failed; skipping AUR packages")"
        warn "$(t "手动装：git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si" "manual: git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si")"
        return 0
    fi

    log "$(t "编译安装（切回 $TARGET_USER）" "building as $TARGET_USER")"
    if [ "${RUN_AS_ROOT:-0}" -eq 1 ]; then
        chown -R "$TARGET_USER:" "$tmp"
        as_user sh -c "cd '$tmp/yay-bin' && makepkg -si --noconfirm" || true
    else
        ( cd "$tmp/yay-bin" && makepkg -si --noconfirm ) || true
    fi

    if command -v yay >/dev/null 2>&1; then
        AUR_HELPER="yay"
        success "$(t "yay 装好了" "yay installed")"
        export AUR_HELPER
    else
        warn "$(t "yay 没装上，AUR 包这个跳过，修好重跑" "yay install failed; AUR packages skipped, rerun later")"
    fi
}

# ------------------------------- 装后对账清单 -------------------------------
export VERIFY_LIST="${VERIFY_LIST:-/tmp/chenpi_install_verify.list}"

# 把打算装的包登记下来，装完由 05-verify.sh 逐个核对
verify_add() {
    local p
    for p in "$@"; do
        [ -n "$p" ] && printf '%s\n' "$p" >> "$VERIFY_LIST"
    done
}

# ------------------------------- 包管理封装 -------------------------------
# 装一批包并登记到对账清单（自动跳过装不了的）
pac_install() {
    local pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && return 0

    local valid=() p
    for p in "${pkgs[@]}"; do
        if pacman -Si "$p" >/dev/null 2>&1; then valid+=("$p"); fi
    done
    if [ ${#valid[@]} -eq 0 ]; then
        warn "$(t "源里找不到这些包：${pkgs[*]}" "not in any configured repo: ${pkgs[*]}")"
        return 1
    fi

    verify_add "${valid[@]}"
    write_log "PAC" "安装 ${#valid[@]} 个官方源包"
    if ! printf '%s\n' "${valid[@]}" | as_root pacman -S --needed --noconfirm -; then
        warn "$(t "整批失败，改成逐个装" "batch failed; installing one by one")"
        local failed=()
        for p in "${valid[@]}"; do
            as_root pacman -S --needed --noconfirm "$p" >/dev/null 2>&1 || failed+=("$p")
        done
        if [ ${#failed[@]} -gt 0 ]; then
            warn "$(t "这些装不上：${failed[*]}" "failed: ${failed[*]}")"
            write_log "PAC-FAIL" "${failed[*]}"
        fi
    fi
}

# 装 AUR 包（用检测到的助手）
aur_install() {
    local pkgs=("$@")
    [ ${#pkgs[@]} -eq 0 ] && return 0
    ensure_aur_helper
    if [ -z "${AUR_HELPER:-}" ]; then
        warn "$(t "没有 AUR 助手，跳过：${pkgs[*]}" "no AUR helper, skipping: ${pkgs[*]}")"
        return 1
    fi
    verify_add "${pkgs[@]}"
    write_log "AUR" "安装 ${#pkgs[@]} 个 AUR 包：${pkgs[*]}"
    if ! "$AUR_HELPER" -S --needed --noconfirm "${pkgs[@]}"; then
        warn "$(t "整批失败，改成逐个装" "batch failed; installing one by one")"
        local p failed=()
        for p in "${pkgs[@]}"; do
            "$AUR_HELPER" -S --needed --noconfirm "$p" >/dev/null 2>&1 || failed+=("$p")
        done
        if [ ${#failed[@]} -gt 0 ]; then
            warn "$(t "这些 AUR 包装不上：${failed[*]}" "AUR packages failed: ${failed[*]}")"
            write_log "AUR-FAIL" "${failed[*]}"
        fi
    fi
}

# 包装上了吗
has_pkg() { pacman -Qq "$1" >/dev/null 2>&1; }

# ------------------------------- 安装期间临时免密 -------------------------------
# 整套脚本会调很多次 sudo，每次都被问密码很烦。规则写在 sudoers.d 里，
# 但**退出时必须删掉**，否则等于在这台机器上留了个永久免密后门。
NOPASSWD_FILE="/etc/sudoers.d/99_chenpi_install_temp"
NOPASSWD_ACTIVE=0

setup_nopasswd() {
    # 本来就是 root 跑的话不需要
    if [ "${RUN_AS_ROOT:-0}" -eq 1 ]; then return 0; fi

    if ! printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" | as_root tee "$NOPASSWD_FILE" >/dev/null 2>&1; then
        warn "$(t "免密规则写不进去，后面会多问几次密码" "could not write NOPASSWD rule; expect more password prompts")"
        return 0
    fi

    # 先校验再启用：sudoers 写坏了会让 sudo 整个失灵，那就麻烦了
    if ! as_root visudo -cf "$NOPASSWD_FILE" >/dev/null 2>&1; then
        as_root rm -f "$NOPASSWD_FILE" 2>/dev/null || true
        warn "$(t "免密规则没通过 visudo 校验，已删除" "NOPASSWD rule failed visudo check; removed")"
        return 0
    fi

    as_root chmod 440 "$NOPASSWD_FILE"
    NOPASSWD_ACTIVE=1
    export NOPASSWD_ACTIVE
    success "$(t "安装期间免密（退出时删除）" "passwordless sudo active (removed on exit)")"
}

cleanup_nopasswd() {
    if [ "${NOPASSWD_ACTIVE:-0}" -eq 1 ]; then
        sudo -n rm -f "$NOPASSWD_FILE" 2>/dev/null || sudo rm -f "$NOPASSWD_FILE" 2>/dev/null || true
        NOPASSWD_ACTIVE=0
    fi
}
