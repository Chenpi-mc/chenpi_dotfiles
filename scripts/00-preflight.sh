#!/bin/bash
# ==============================================================================
# 00-preflight.sh — 动手之前先把这台机器的底细摸清楚
#
# 这个模块是整套脚本的第一步，只做**只读检查**，一个字都不改系统。
# 目的：把系统情况全部打进日志和报告，并在发现致命问题时就地拦住，
# 免得跑到一半才发现「这机器根本不是 Arch」或者「磁盘只剩 1G」。
#
# 结果会写进 $REPORT，主控跑完会把它存到 ~/Documents/ 一份。
# 真想跳过拦阻（比如你确认没问题）：CHENPI_IGNORE_PREFLIGHT=1 ./install.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

SRC="$REPO_ROOT/dotfiles"

TARGET_USER="${TARGET_USER:-$(id -un)}"
TARGET_HOME="${TARGET_HOME:-$HOME}"
RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER TARGET_HOME RUN_AS_ROOT

REPORT="/tmp/chenpi-preflight.txt"
: > "$REPORT"

CRITICAL_COUNT=0
WARN_COUNT=0

# 每一项检查都同时：打屏 + 进日志 + 进报告文件
report_add() {
    printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$REPORT"
}
check() {
    local k="$1" v="$2" note="${3:-}"
    info_kv "$k" "$v" "$note"
    report_add "$k: $v $note"
}
critical() {
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    echo -e "   ${H_RED}${BOLD}✘ 致命：$1${NC}"
    report_add "致命: $1"
    write_log "CRITICAL" "$1"
}
soft_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "   ${H_YELLOW}⚠ 注意：$1${NC}"
    report_add "注意: $1"
    write_log "PREWARN" "$1"
}

report_add "===== 装机前系统检查 $(date '+%Y-%m-%d %H:%M:%S') ====="

# ==============================================================================
# 1. 基础环境
# ==============================================================================
section "1. 基础环境" "发行版 / 内核 / 架构 / 运行环境"

if command -v pacman >/dev/null 2>&1; then
    check "pacman" "$(pacman -V 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)" "包管理器正常"
    check "发行版" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-未知}")" ""
    check "内核" "$(uname -r)" "$(uname -m)"
else
    check "发行版" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-未知}")" ""
    critical "找不到 pacman —— 这不是 Arch Linux，本脚本装不了"
fi

check "运行用户" "$(id -un)" "$([ "$RUN_AS_ROOT" -eq 1 ] && echo "(root，属主会改回 $TARGET_USER)" || echo "(普通用户，内部走 sudo)")"
check "配置仓库" "$REPO_ROOT" "$(du -sh "$REPO_ROOT" 2>/dev/null | cut -f1)"

# Live 环境跑会装到 U 盘上，白费功夫
if [ -d /run/archiso ] || [ "$(findmnt -no FSTYPE / 2>/dev/null)" = "overlay" ]; then
    critical "现在跑在 Arch 安装盘的 Live 环境里，得先装好系统、重启进真实系统再跑"
else
    check "运行环境" "已安装的系统" "不是 Live 环境"
fi

# ==============================================================================
# 2. 硬件
# ==============================================================================
section "2. 硬件" "CPU / 内存 / 显卡"

if [ -r /proc/cpuinfo ]; then
    cpu_model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
    cpu_cores="$(grep -c '^processor' /proc/cpuinfo || echo '?')"
    check "CPU" "${cpu_model:-未知}" "${cpu_cores} 线程"
fi

if [ -r /proc/meminfo ]; then
    mem_total="$(awk '/^MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
    mem_avail="$(awk '/^MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)"
    check "内存" "${mem_total} GiB" "当前可用 ${mem_avail} GiB"
    # niri 本身就是 Rust 编译，内存太小会很难受
    if awk "BEGIN{exit !($mem_total < 3.5)}"; then
        soft_warn "内存只有 ${mem_total} GiB，编译 niri 那类包可能因为内存不够失败；建议先加 swap"
    fi
fi

if command -v lspci >/dev/null 2>&1; then
    # set -o pipefail 下，管道里 grep 没匹配到（返回 1）会让整条管道失败，
    # 赋值语句跟着失败，配 set -e 脚本当场退出 —— 所以每个管道都得兜底
    gpu_list="$(lspci 2>/dev/null | grep -E -i 'vga|3d|display' | sed 's/.*: //' | paste -sd' | ' - || true)"
    check "显卡" "${gpu_list:-没认出来}" ""
    nvidia_n="$(lspci 2>/dev/null | grep -ci nvidia || true)"
    gpu_n="$(lspci 2>/dev/null | grep -E -i 'vga|3d|display' | wc -l || true)"
    if [ "${nvidia_n:-0}" -gt 0 ] && [ "${gpu_n:-0}" -gt 1 ]; then
        soft_warn "双显卡（NVIDIA + 核显）——后面装驱动要用 nvidia-open-dkms 这类，03b 模块会处理"
    fi
else
    soft_warn "没装 pciutils（缺 lspci），显卡检测会跳过；03b 模块会补装"
fi

# ==============================================================================
# 3. 磁盘与文件系统
# ==============================================================================
section "3. 磁盘与文件系统" "空间够不够是整个安装的前提"

root_fs="$(findmnt -no FSTYPE / 2>/dev/null || echo 未知)"
check "根分区文件系统" "$root_fs" "$(findmnt -no SOURCE / 2>/dev/null)"

avail_g="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')"
size_g="$(df -BG --output=size / 2>/dev/null | tail -1 | tr -dc '0-9')"
used_pct="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${avail_g:-}" ]; then
    check "根分区空间" "总 ${size_g}G / 可用 ${avail_g}G" "已用 ${used_pct}%"
    if [ "$avail_g" -lt 5 ]; then
        critical "根分区只剩 ${avail_g}G。这套流程要装 200 来个包，还要从源码编译 niri，至少留 10G 才稳妥"
    elif [ "$avail_g" -lt 10 ]; then
        soft_warn "根分区只剩 ${avail_g}G，装包 + 编译 niri 可能会撑爆，建议先清一清"
    fi
fi

if [ "$root_fs" = "btrfs" ]; then
    check "btrfs 子卷" "$(findmnt -no OPTIONS / 2>/dev/null | grep -o 'subvol=[^,]*' || echo 'subvol=/')" ""
    if command -v snapper >/dev/null 2>&1; then
        if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
            check "snapper" "已配置" "00-btrfs-init 会跳过重复配置"
        else
            check "snapper" "已装但没配 root" "00-btrfs-init 会给它建配置"
        fi
    else
        check "snapper" "没装" "00-btrfs-init 会装并配置快照"
    fi
    if [ -e /.snapshots ]; then
        check "/.snapshots" "已存在" ""
    fi
else
    soft_warn "根分区不是 btrfs（现在是 $root_fs），快照那套会用不上，00-btrfs-init 会自动跳过"
fi

if [ -d /home ] && findmnt -no FSTYPE /home >/dev/null 2>&1; then
    check "/home" "$(findmnt -no FSTYPE /home 2>/dev/null)" "$(findmnt -no SOURCE /home 2>/dev/null)"
fi

# ==============================================================================
# 4. 引导方式
# ==============================================================================
section "4. 引导" "BIOS/UEFI、引导器、/boot 布局"

if [ -d /sys/firmware/efi ]; then
    check "固件" "UEFI" ""
    if command -v bootctl >/dev/null 2>&1 && bootctl is-installed >/dev/null 2>&1; then
        check "引导器" "systemd-boot" "GRUB 相关的模块会自动跳过"
    elif [ -f /boot/grub/grub.cfg ] || [ -f /boot/grub2/grub.cfg ]; then
        check "引导器" "GRUB" "/boot/grub/grub.cfg 在"
    else
        check "引导器" "没识别出来" ""
        blank_boot="$(ls /boot 2>/dev/null | grep -iE 'vmlinuz|initramfs' | wc -l || true)"
        if [ "$blank_boot" -gt 0 ]; then
            soft_warn "/boot 里有内核但没找到 grub.cfg，可能是 UKI 或自定义布局；GRUB 相关模块会跳过"
        fi
    fi
else
    check "固件" "BIOS（传统引导）" ""
fi

if [ -e /boot/grub/grub.cfg ]; then
    check "grub.cfg" "存在" "$(stat -c %y /boot/grub/grub.cfg 2>/dev/null | cut -d. -f1)"
fi
if [ -f /etc/default/grub ]; then
    grub_default="$(grep -E '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2 || true)"
    grub_saved="$(grep -E '^GRUB_SAVEDEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2 || true)"
    check "GRUB_DEFAULT" "${grub_default:-未设置}" "SAVEDEFAULT=${grub_saved:-未设置}"
fi

# ==============================================================================
# 5. 桌面环境现状
# ==============================================================================
section "5. 桌面环境现状" "现在这台机器上有什么"

check_dm_conflict
if [ -n "${DM_FOUND:-}" ]; then
    report_add "显示管理器: $DM_FOUND（已启用: ${DM_ENABLED:-无}）"
fi

if command -v niri >/dev/null 2>&1; then
    # pacman -Qo 的输出会跟着系统语言变，用 LC_ALL=C 固定成英文才好解析字段
    niri_owner="$(LC_ALL=C pacman -Qo "$(command -v niri)" 2>/dev/null | awk '{print $(NF-1)}' || echo 未知)"
    check "niri" "已安装" "来自 $niri_owner"
    case "$niri_owner" in
        *shorin-fork*)
            check "niri 类型" "shorin 分叉版" "配置里用到的网格/放大镜/录屏特性要靠它"
            ;;
        niri*)
            soft_warn "你装的是上游 niri，但配置如果用了分叉特性会报错；新机器建议装 niri-shorin-fork-git"
            ;;
    esac
else
    check "niri" "没装" "99-apps 会按 pkglist 装上"
fi

if command -v yay >/dev/null 2>&1; then
    check "AUR 助手" "yay 已装" ""
elif command -v paru >/dev/null 2>&1; then
    check "AUR 助手" "paru 已装" ""
else
    check "AUR 助手" "都没有" "01a 模块会先看源里有没有，没有才自举"
fi

# ==============================================================================
# 6. 网络
# ==============================================================================
section "6. 网络" "能不能下到包"

if command -v curl >/dev/null 2>&1; then
    if curl -sI --max-time 10 https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db >/dev/null 2>&1; then
        check "Arch 官方镜像" "可以连上" ""
    else
        soft_warn "连不上 Arch 官方镜像。装了代理的话记得先设环境变量，否则装包会失败"
    fi
    if curl -sI --max-time 10 https://aur.archlinux.org >/dev/null 2>&1; then
        check "AUR" "可以连上" ""
    else
        soft_warn "连不上 AUR —— AUR 包（含 niri 分叉）会装不上"
    fi
else
    soft_warn "没装 curl，网络检查跳过"
fi

if [ -f /etc/pacman.d/mirrorlist ]; then
    check "mirrorlist" "$(grep -c '^Server' /etc/pacman.d/mirrorlist 2>/dev/null || echo 0) 个 Server" ""
fi

# ==============================================================================
# 7. 系统设置与前置依赖
# ==============================================================================
section "7. 系统设置与依赖" "时区 / 语言 / 编译工具"

check "时区" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 未知)" ""
check "LANG" "${LANG:-未设置}" ""

if [ -f /etc/locale.gen ]; then
    gen_n="$(grep -cE '^(en_US|zh_CN)\.' /etc/locale.gen 2>/dev/null || echo 0)"
    if locale -a 2>/dev/null | grep -qi 'zh_CN.utf8'; then
        zh_state="中文 locale 已生成"
    else
        zh_state="中文 locale 还没生成"
    fi
    check "locale" "${gen_n} 条 en_US/zh_CN 已启用" "$zh_state"
fi

for p in base-devel git curl; do
    if pacman -Qq "$p" >/dev/null 2>&1; then
        check "$p" "已装" ""
    else
        soft_warn "$p 没装 —— 编译 AUR 包（niri 分叉等）会失败，01a 会补"
    fi
done

if pacman -Dk >/dev/null 2>&1; then
    check "pacman 数据库" "健康" ""
else
    soft_warn "pacman 数据库有报错，装包前建议先修（pacman -Dk 看详情）"
fi

# ==============================================================================
# 8. 现有配置与仓库自检
# ==============================================================================
section "8. 现有配置与仓库自检" "会被覆盖的东西先看清楚"

if [ -d "$TARGET_HOME/.config" ]; then
    exist_n="$(ls -A "$TARGET_HOME/.config" 2>/dev/null | wc -l)"
    check "现有 ~/.config" "$exist_n 项" "会被 04 模块覆盖（覆盖前自动 tar 备份）"
    if [ "$exist_n" -gt 60 ]; then
        soft_warn "这台机器看起来已经装好一套环境了。跑下去会用仓库里的配置覆盖它（有备份，但先确认这是你要的）"
    fi
else
    check "现有 ~/.config" "不存在" "像是全新机器"
fi

if [ -d "$SRC/.config" ]; then
    check "仓库 .config" "$(ls -A "$SRC/.config" 2>/dev/null | wc -l) 项" "$(du -sh "$SRC/.config" 2>/dev/null | cut -f1)"
else
    critical "仓库里没有 dotfiles/.config —— 配置是空的，装上也没东西可恢复"
fi

if [ -d "$SRC/chenpi_file/wallpaper" ]; then
    check "仓库壁纸" "$(find "$SRC/chenpi_file/wallpaper" -type f 2>/dev/null | wc -l) 个文件" ""
else
    soft_warn "仓库里没有壁纸目录"
fi

for f in pkglist.txt pkglist-aur.txt; do
    if [ -f "$SRC/$f" ]; then
        check "$f" "$(grep -cvE '^\s*(#|$)' "$SRC/$f" 2>/dev/null || echo 0) 个包" ""
    else
        soft_warn "仓库里没有 $f"
    fi
done

if [ -d "$REPO_ROOT/etc" ]; then
    check "仓库 /etc 配置" "$(find "$REPO_ROOT/etc" -type f 2>/dev/null | wc -l) 个文件" ""
fi

# ==============================================================================
# 结论
# ==============================================================================
section "检查结论" "先看清楚再动手"

report_add ""
report_add "致命问题 $CRITICAL_COUNT 个 / 注意项 $WARN_COUNT 个"
report_add "报告文件: $REPORT"

info_kv "致命问题" "$CRITICAL_COUNT 个" "$([ "$CRITICAL_COUNT" -gt 0 ] && echo '必须先解决' || echo '无')"
info_kv "注意项" "$WARN_COUNT 个" "$([ "$WARN_COUNT" -gt 0 ] && echo '不拦，但最好看一眼' || echo '无')"
info_kv "报告文件" "$REPORT" "跑完会存一份到 ~/Documents"

if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo ""
    if [ "${CHENPI_IGNORE_PREFLIGHT:-0}" = "1" ]; then
        warn "检测到 $CRITICAL_COUNT 个致命问题，但你设了 CHENPI_IGNORE_PREFLIGHT=1，硬着头皮继续"
        exit 0
    fi
    error "有 $CRITICAL_COUNT 个致命问题，先解决再跑。上面每一项都写了原因"
    echo -e "   ${DIM}确定没问题、想强行继续的话：CHENPI_IGNORE_PREFLIGHT=1 ./install.sh${NC}"
    exit 1
fi

success "系统检查通过，可以往下走"
exit 0
