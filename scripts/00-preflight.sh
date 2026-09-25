#!/bin/bash
# ==============================================================================
# 00-preflight.sh — 动手之前先摸清这台机器（只读，不改系统）
#
# 有致命问题就地拦住，免得跑到一半才发现装不了。
# 结果写进 $REPORT，主控跑完会存一份到 ~/Documents。
# 想跳过拦阻：CHENPI_IGNORE_PREFLIGHT=1 ./install.sh
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

# 报告路径可以被主控覆盖（/tmp 满了的时候能换个地方写）
REPORT="${PREFLIGHT_REPORT:-/tmp/chenpi-preflight.txt}"
: > "$REPORT"

# PREFLIGHT_QUIET=1：只在屏幕上打「注意/致命」，详细清单只看报告文件
QUIET="${PREFLIGHT_QUIET:-0}"

CRITICAL_COUNT=0
WARN_COUNT=0

report_add() {
    printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$REPORT"
}
check() {
    local k="$1" v="$2" note="${3:-}"
    if [ "$QUIET" -eq 0 ]; then info_kv "$k" "$v" "$note"; fi
    report_add "$k: $v $note"
}

# 安静模式下不打印分节标题
psec() {
    # 必须写成 if：用 `[ ] && cmd` 的话，条件为假时函数返回 1，set -e 会直接结束脚本
    if [ "$QUIET" -eq 0 ]; then
        section "$1" "${2:-}"
    fi
    return 0
}
critical() {
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
    echo -e "   ${H_RED}${BOLD}✘ $(t "致命：" "FATAL: ")$1${NC}"
    report_add "$(t "致命: " "FATAL: ")$1"
    write_log "CRITICAL" "$1"
}
soft_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "   ${H_YELLOW}⚠ $(t "注意：" "WARN: ")$1${NC}"
    report_add "$(t "注意: " "WARN: ")$1"
    write_log "PREWARN" "$1"
}

report_add "$(t "装机前检查" "Preflight") $(date '+%Y-%m-%d %H:%M:%S')"

# ==============================================================================
# 1. 基础环境
# ==============================================================================
psec "$(t "1. 基础环境" "1. Base env")" "$(t "发行版 / 内核" "distro / kernel")"

if command -v pacman >/dev/null 2>&1; then
    check "pacman" "$(pacman -V 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)" "$(t "包管理器正常" "pacman ok")"
    check "$(t "发行版" "distro")" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$(t "未知" "unknown")}")" ""
    check "$(t "内核" "kernel")" "$(uname -r)" "$(uname -m)"
else
    check "$(t "发行版" "distro")" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$(t "未知" "unknown")}")" ""
    critical "$(t "找不到 pacman，这不是 Arch Linux" "no pacman — not Arch Linux")"
fi

check "$(t "运行用户" "user")" "$(id -un)" "$([ "$RUN_AS_ROOT" -eq 1 ] && echo "$(t "root，属主会改回 $TARGET_USER" "root, owner reset to $TARGET_USER")" || echo "$(t "普通用户，内部走 sudo" "normal user, sudo inside")")"
check "$(t "配置仓库" "repo")" "$REPO_ROOT" "$(du -sh "$REPO_ROOT" 2>/dev/null | cut -f1)"

# Live 环境跑会装到 U 盘上，白费功夫
if [ -d /run/archiso ] || [ "$(findmnt -no FSTYPE / 2>/dev/null)" = "overlay" ]; then
    critical "$(t "现在跑在 Live 环境里，先装好系统重启再跑" "running in Live environment — install the system first")"
else
    check "$(t "运行环境" "environment")" "$(t "已安装的系统" "installed system")" "$(t "不是 Live" "not Live")"
fi

# ==============================================================================
# 2. 硬件
# ==============================================================================
psec "$(t "2. 硬件" "2. Hardware")" "$(t "CPU / 内存 / 显卡" "CPU / RAM / GPU")"

if [ -r /proc/cpuinfo ]; then
    cpu_model="$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
    cpu_cores="$(grep -c '^processor' /proc/cpuinfo || echo '?')"
    check "CPU" "${cpu_model:-$(t "未知" "unknown")}" "$(t "${cpu_cores} 线程" "${cpu_cores} threads")"
fi

if [ -r /proc/meminfo ]; then
    mem_total="$(awk '/^MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
    mem_avail="$(awk '/^MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)"
    check "$(t "内存" "RAM")" "${mem_total} GiB" "$(t "可用 ${mem_avail} GiB" "${mem_avail} GiB free")"
    # niri 是 Rust 编译，内存太小会很痛苦
    if awk "BEGIN{exit !($mem_total < 3.5)}"; then
        soft_warn "$(t "内存只有 ${mem_total} GiB，编译 niri 可能失败，建议加 swap" "only ${mem_total} GiB RAM — compiling niri may fail, add swap")"
    fi
fi

if command -v lspci >/dev/null 2>&1; then
    # 【坑】set -o pipefail 下，赋值里的管道只要有一环返回非零（grep 没匹配也算），
    # 赋值就失败，配 set -e 脚本当场退出 —— 每个管道都要 || true 兜底
    gpu_list="$(lspci 2>/dev/null | grep -E -i 'vga|3d|display' | sed 's/.*: //' | paste -sd' | ' - || true)"
    check "$(t "显卡" "GPU")" "${gpu_list:-$(t "没认出来" "unknown")}" ""
    nvidia_n="$(lspci 2>/dev/null | grep -ci nvidia || true)"
    gpu_n="$(lspci 2>/dev/null | grep -E -i 'vga|3d|display' | wc -l || true)"
    if [ "${nvidia_n:-0}" -gt 0 ] && [ "${gpu_n:-0}" -gt 1 ]; then
        soft_warn "$(t "双显卡，03b 会装 nvidia-open-dkms 这类驱动" "hybrid GPU — 03b installs nvidia-open-dkms")"
    fi
else
    soft_warn "$(t "没装 pciutils（缺 lspci），显卡检测跳过，03b 会补装" "no pciutils/lspci — GPU check skipped, 03b installs it")"
fi

# ==============================================================================
# 3. 磁盘
# ==============================================================================
psec "$(t "3. 磁盘" "3. Disk")" "$(t "空间" "space")"

root_fs="$(findmnt -no FSTYPE / 2>/dev/null || echo "$(t "未知" "unknown")")"
check "$(t "根分区文件系统" "root fs")" "$root_fs" "$(findmnt -no SOURCE / 2>/dev/null)"

# 同样：赋值里的管道一律 || true，不然 df 一出错脚本就没了
avail_g="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
size_g="$(df -BG --output=size / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
used_pct="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
if [ -n "${avail_g:-}" ]; then
    check "$(t "根分区空间" "root space")" "$(t "总 ${size_g}G / 可用 ${avail_g}G" "${size_g}G total / ${avail_g}G free")" "$(t "已用 ${used_pct}%" "${used_pct}% used")"
    if [ "$avail_g" -lt 5 ]; then
        critical "$(t "根分区只剩 ${avail_g}G，装包 + 编译 niri 至少要 10G" "only ${avail_g}G free on /, need 10G+")"
    elif [ "$avail_g" -lt 10 ]; then
        soft_warn "$(t "根分区只剩 ${avail_g}G，可能撑爆，建议先清理" "only ${avail_g}G free on / — clean up first")"
    fi
fi

if [ "$root_fs" = "btrfs" ]; then
    check "$(t "btrfs 子卷" "btrfs subvol")" "$(findmnt -no OPTIONS / 2>/dev/null | grep -o 'subvol=[^,]*' || echo 'subvol=/')" ""
    if command -v snapper >/dev/null 2>&1; then
        # 只读探测用 as_root_quiet：体检阶段不该弹 sudo 密码
        if as_root_quiet snapper list-configs 2>/dev/null | grep -q '^root '; then
            check "snapper" "$(t "已配置" "configured")" "$(t "00-btrfs-init 会跳过" "00-btrfs-init skips")"
        else
            check "snapper" "$(t "已装但没配 root" "installed, no root config")" "$(t "00-btrfs-init 会创建" "00-btrfs-init creates it")"
        fi
    else
        check "snapper" "$(t "没装" "not installed")" "$(t "00-btrfs-init 会装并配置" "00-btrfs-init installs it")"
    fi
    if [ -e /.snapshots ]; then
        check "/.snapshots" "$(t "已存在" "exists")" ""
    fi
else
    soft_warn "$(t "根分区不是 btrfs（现在是 $root_fs），快照会用不上，00-btrfs-init 会自动跳过" "root fs is $root_fs, not btrfs — snapshots skipped")"
fi

if [ -d /home ] && findmnt -no FSTYPE /home >/dev/null 2>&1; then
    check "/home" "$(findmnt -no FSTYPE /home 2>/dev/null)" "$(findmnt -no SOURCE /home 2>/dev/null)"
fi

# ==============================================================================
# 4. 引导
# ==============================================================================
psec "$(t "4. 引导" "4. Boot")" "$(t "固件 / 引导器" "firmware / bootloader")"

if [ -d /sys/firmware/efi ]; then
    check "$(t "固件" "firmware")" "UEFI" ""
    if command -v bootctl >/dev/null 2>&1 && bootctl is-installed >/dev/null 2>&1; then
        check "$(t "引导器" "bootloader")" "systemd-boot" "$(t "GRUB 模块会跳过" "GRUB modules skipped")"
    elif [ -f /boot/grub/grub.cfg ] || [ -f /boot/grub2/grub.cfg ]; then
        check "$(t "引导器" "bootloader")" "GRUB" "$(t "grub.cfg 在" "grub.cfg present")"
    else
        check "$(t "引导器" "bootloader")" "$(t "没识别出来" "unrecognized")" ""
        blank_boot="$(ls /boot 2>/dev/null | grep -iE 'vmlinuz|initramfs' | wc -l || true)"
        if [ "$blank_boot" -gt 0 ]; then
            soft_warn "$(t "/boot 里有内核但没找到 grub.cfg，可能是 UKI；GRUB 模块会跳过" "kernel in /boot but no grub.cfg (UKI?); GRUB skipped")"
        fi
    fi
else
    check "$(t "固件" "firmware")" "$(t "BIOS（传统引导）" "BIOS (legacy)")" ""
fi

if [ -e /boot/grub/grub.cfg ]; then
    check "grub.cfg" "$(t "存在" "exists")" "$(stat -c %y /boot/grub/grub.cfg 2>/dev/null | cut -d. -f1)"
fi
if [ -f /etc/default/grub ]; then
    grub_default="$(grep -E '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2 || true)"
    grub_saved="$(grep -E '^GRUB_SAVEDEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2 || true)"
    check "GRUB_DEFAULT" "${grub_default:-$(t "未设置" "unset")}" "SAVEDEFAULT=${grub_saved:-$(t "未设置" "unset")}"
fi

# ==============================================================================
# 5. 桌面现状
# ==============================================================================
psec "$(t "5. 桌面现状" "5. Desktop")" ""

check_dm_conflict
if [ -n "${DM_FOUND:-}" ]; then
    report_add "$(t "显示管理器: " "DM: ")$DM_FOUND $(t "已启用: ${DM_ENABLED:-无}" "enabled: ${DM_ENABLED:-none}")"
fi

if command -v niri >/dev/null 2>&1; then
    # 【坑】pacman -Qo 的输出跟着系统语言变，用 LC_ALL=C 固定英文才好切字段
    niri_owner="$(LC_ALL=C pacman -Qo "$(command -v niri)" 2>/dev/null | awk '{print $(NF-1)}' || echo "$(t "未知" "unknown")")"
    check "niri" "$(t "已安装" "installed")" "$(t "来自 $niri_owner" "from $niri_owner")"
    case "$niri_owner" in
        *shorin-fork*)
            check "$(t "niri 类型" "niri variant")" "$(t "shorin 分叉版" "shorin fork")" "$(t "网格/放大镜/录屏要靠它" "needed for grid/magnifier/recording")"
            ;;
        niri*)
            soft_warn "$(t "你装的是上游 niri，分叉特性会报错；建议 niri-shorin-fork-git" "upstream niri — fork features will break; use niri-shorin-fork-git")"
            ;;
    esac
else
    check "niri" "$(t "没装" "not installed")" "$(t "99-apps 会装" "99-apps installs it")"
fi

if command -v yay >/dev/null 2>&1; then
    check "$(t "AUR 助手" "AUR helper")" "$(t "yay 已装" "yay")" ""
elif command -v paru >/dev/null 2>&1; then
    check "$(t "AUR 助手" "AUR helper")" "$(t "paru 已装" "paru")" ""
else
    check "$(t "AUR 助手" "AUR helper")" "$(t "都没有" "none")" "$(t "01a 会先看源再自举" "01a bootstraps if needed")"
fi

# ==============================================================================
# 6. 网络
# ==============================================================================
psec "$(t "6. 网络" "6. Network")" "$(t "镜像源" "mirrors")"

if command -v curl >/dev/null 2>&1; then
    if curl -sI --max-time 10 https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db >/dev/null 2>&1; then
        check "$(t "Arch 官方镜像" "Arch mirrors")" "$(t "可以连上" "reachable")" ""
    else
        soft_warn "$(t "连不上 Arch 官方镜像；用代理的话先设环境变量" "cannot reach Arch mirrors — set proxy env vars first")"
    fi
    if curl -sI --max-time 10 https://aur.archlinux.org >/dev/null 2>&1; then
        check "AUR" "$(t "可以连上" "reachable")" ""
    else
        soft_warn "$(t "连不上 AUR，AUR 包（含 niri 分叉）会装不上" "cannot reach AUR — AUR packages will fail")"
    fi
else
    soft_warn "$(t "没装 curl，网络检查跳过" "no curl — network check skipped")"
fi

if [ -f /etc/pacman.d/mirrorlist ]; then
    check "mirrorlist" "$(grep -c '^Server' /etc/pacman.d/mirrorlist 2>/dev/null || echo 0) $(t "个 Server" "servers")" ""
fi

# ==============================================================================
# 7. 系统设置与依赖
# ==============================================================================
psec "$(t "7. 系统设置" "7. System")" "$(t "时区 / 语言" "timezone / locale")"

check "$(t "时区" "timezone")" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "$(t "未知" "unknown")")" ""
check "LANG" "${LANG:-$(t "未设置" "unset")}" ""

if [ -f /etc/locale.gen ]; then
    gen_n="$(grep -cE '^(en_US|zh_CN)\.' /etc/locale.gen 2>/dev/null || echo 0)"
    if locale -a 2>/dev/null | grep -qi 'zh_CN.utf8'; then
        zh_state="$(t "中文 locale 已生成" "zh_CN locale present")"
    else
        zh_state="$(t "中文 locale 还没生成" "zh_CN locale missing")"
    fi
    check "locale" "$(t "$gen_n 条 en_US/zh_CN" "$gen_n en_US/zh_CN entries")" "$zh_state"
fi

for p in base-devel git curl; do
    if pacman -Qq "$p" >/dev/null 2>&1; then
        check "$p" "$(t "已装" "installed")" ""
    else
        soft_warn "$(t "$p 没装，编译 AUR 包会失败，01a 会补" "$p missing — AUR builds fail, 01a installs it")"
    fi
done

if pacman -Dk >/dev/null 2>&1; then
    check "$(t "pacman 数据库" "pacman db")" "$(t "健康" "healthy")" ""
else
    soft_warn "$(t "pacman 数据库有报错，装包前先修（pacman -Dk 看详情）" "pacman db has errors — fix first (pacman -Dk)")"
fi

# ==============================================================================
# 8. 现有配置与仓库自检
# ==============================================================================
psec "$(t "8. 现有配置" "8. Existing config")" "$(t "覆盖前先看清" "will be overwritten")"

if [ -d "$TARGET_HOME/.config" ]; then
    exist_n="$(ls -A "$TARGET_HOME/.config" 2>/dev/null | wc -l || true)"
    check "$(t "现有 ~/.config" "current ~/.config")" "$(t "$exist_n 项" "$exist_n items")" "$(t "04 会覆盖（覆盖前自动备份）" "04 overwrites it (backed up first)")"
    if [ "$exist_n" -gt 60 ]; then
        soft_warn "$(t "这台机器看着已经有一整套环境了，跑下去会覆盖（有备份，先确认是你要的）" "already looks like a full desktop — it will be overwritten (backup exists)")"
    fi
else
    check "$(t "现有 ~/.config" "current ~/.config")" "$(t "不存在" "absent")" "$(t "像是全新机器" "looks fresh")"
fi

if [ -d "$SRC/.config" ]; then
    src_n="$(ls -A "$SRC/.config" 2>/dev/null | wc -l || true)"
    check "$(t "仓库 .config" "repo .config")" "$(t "$src_n 项" "$src_n items")" "$(du -sh "$SRC/.config" 2>/dev/null | cut -f1)"
else
    critical "$(t "仓库里没有 dotfiles/.config，装上也没东西可恢复" "no dotfiles/.config in repo — nothing to restore")"
fi

if [ -d "$SRC/chenpi_file/wallpaper" ]; then
    wp_n="$(find "$SRC/chenpi_file/wallpaper" -type f 2>/dev/null | wc -l || true)"
    check "$(t "仓库壁纸" "wallpapers")" "$(t "$wp_n 个文件" "$wp_n files")" ""
else
    soft_warn "$(t "仓库里没有壁纸目录" "no wallpaper directory in repo")"
fi

for f in pkglist.txt pkglist-aur.txt; do
    if [ -f "$SRC/$f" ]; then
        check "$f" "$(grep -cvE '^\s*(#|$)' "$SRC/$f" 2>/dev/null || echo 0) $(t "个包" "pkgs")" ""
    else
        soft_warn "$(t "仓库里没有 $f" "no $f in repo")"
    fi
done

if [ -d "$REPO_ROOT/etc" ]; then
    etc_n="$(find "$REPO_ROOT/etc" -type f 2>/dev/null | wc -l || true)"
    check "$(t "仓库 /etc 配置" "repo /etc")" "$(t "$etc_n 个文件" "$etc_n files")" ""
fi

# ==============================================================================
# 结论
# ==============================================================================
psec "$(t "检查结论" "Summary")" ""

report_add ""
report_add "$(t "致命问题 $CRITICAL_COUNT 个 / 注意项 $WARN_COUNT 个" "$CRITICAL_COUNT critical / $WARN_COUNT warnings")"
report_add "$(t "报告文件: " "report: ")$REPORT"

info_kv "$(t "致命问题" "critical")" "$(t "$CRITICAL_COUNT 个" "$CRITICAL_COUNT")" "$([ "$CRITICAL_COUNT" -gt 0 ] && echo "$(t "必须先解决" "must fix first")" || echo "$(t "无" "none")")"
info_kv "$(t "注意项" "warnings")" "$(t "$WARN_COUNT 个" "$WARN_COUNT")" "$([ "$WARN_COUNT" -gt 0 ] && echo "$(t "不拦，但最好看一眼" "not fatal, worth a look")" || echo "$(t "无" "none")")"
info_kv "$(t "报告文件" "report file")" "$REPORT" "$(t "跑完会存一份到 ~/Documents" "copied to ~/Documents at the end")"

if [ "$CRITICAL_COUNT" -gt 0 ]; then
    echo ""
    if [ "${CHENPI_IGNORE_PREFLIGHT:-0}" = "1" ]; then
        warn "$(t "有 $CRITICAL_COUNT 个致命问题，但 CHENPI_IGNORE_PREFLIGHT=1，硬着头皮继续" "$CRITICAL_COUNT critical issues, but CHENPI_IGNORE_PREFLIGHT=1 — continuing")"
        exit 0
    fi
    error "$(t "有 $CRITICAL_COUNT 个致命问题，先解决再跑" "$CRITICAL_COUNT critical issues — fix them and rerun")"
    echo -e "   ${DIM}$(t "确定没问题、想强行继续：CHENPI_IGNORE_PREFLIGHT=1 ./install.sh" "to force it: CHENPI_IGNORE_PREFLIGHT=1 ./install.sh")${NC}"
    exit 1
fi

success "$(t "系统检查通过" "preflight passed")"
exit 0
