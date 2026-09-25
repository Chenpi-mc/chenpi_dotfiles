#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 02c-dualboot-fix.sh — 让 GRUB 认出同一块硬盘上另一个分区里的 Windows
#
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/02c-dualboot-fix.sh（AGPL-3.0）。
#
# 背景：GRUB 从 2.06 开始默认不再自动探测其他操作系统
#       （/etc/default/grub 里 GRUB_DISABLE_OS_PROBER 默认 true），
#       于是双系统机器装完 Arch 常常只剩 Arch 一个启动项，Windows 不见了。
# 做法：装 os-prober，在 /etc/default/grub 里显式设 GRUB_DISABLE_OS_PROBER=false，
#       再重建 grub.cfg。
# 本模块不动分区表、不碰 Windows 的引导器，纯 GRUB 侧配置，最坏情况就是没加启动项。
# 和参考版的区别：不调 check_root（改系统走 as_root）、装包用 pac_install、
# 改配置前强制备份、找不到 Windows 时安静跳过而不是报错。
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. 是不是 GRUB 启动
# ------------------------------------------------------------------------------
section "02c · 准备" "检查引导器"

if ! command -v grub-mkconfig >/dev/null 2>&1 || [ ! -f /etc/default/grub ]; then
    warn "没检测到 GRUB（grub-mkconfig 或 /etc/default/grub 缺失）"
    log "用的是别的引导器（systemd-boot 之类）就不需要本模块，直接跳过"
    exit 0
fi
success "检测到 GRUB"

# ------------------------------------------------------------------------------
# 1. 装探测 Windows 需要的工具
# ------------------------------------------------------------------------------
section "02c · 步骤 1/3" "安装 os-prober 及相关工具"

# os-prober 要逐个挂载分区、读里面的引导文件才能确认是哪个系统，
# 所以顺带把 NTFS / exFAT 支持装上，否则它读不动 Windows 分区（会报挂载失败）。
log "装 os-prober 和文件系统工具"
pac_install os-prober ntfs-3g exfatprogs fuse3 || true

if ! command -v os-prober >/dev/null 2>&1; then
    warn "os-prober 没装上，后面的检测和 GRUB 重建都跳过"
    log "手动补装：sudo pacman -S --needed os-prober，然后重跑本模块"
    exit 0
fi
success "os-prober 就绪"

# ------------------------------------------------------------------------------
# 2. 扫描 Windows
# ------------------------------------------------------------------------------
section "02c · 步骤 2/3" "扫描其他操作系统"

# os-prober 必须 root 跑（要挂载分区），可能要十几秒
log "开始扫描（有多个分区时会逐个挂载，慢一点正常）"
PROBE_OUT="$(as_root os-prober 2>/dev/null || true)"

if [ -n "$PROBE_OUT" ]; then
    log "os-prober 输出："
    while IFS= read -r probe_line; do
        if [ -n "$probe_line" ]; then
            log "  $probe_line"
        fi
    done <<< "$PROBE_OUT"
else
    warn "os-prober 什么都没探到"
fi

if ! printf '%s\n' "$PROBE_OUT" | grep -qi 'windows'; then
    warn "没找到 Windows 安装，不改 GRUB 配置，跳过（这不算失败）"
    log "常见原因："
    log "  1) Windows 快速启动/休眠残留：先进 Windows 关掉「快速启动」，然后关机（不是重启）再试"
    log "  2) Windows 分区被 BitLocker 加密，os-prober 读不到里面的内容"
    log "  3) 两块硬盘各带独立 ESP，靠 BIOS 启动菜单切换反而更省事"
    log "  4) 挂载失败：先手动挂一次那个分区（mount -L 卷标），再重跑本模块"
    exit 0
fi
success "找到 Windows"

# ------------------------------------------------------------------------------
# 3. 打开 os-prober + 重建 GRUB
# ------------------------------------------------------------------------------
section "02c · 步骤 3/3" "开启 os-prober 并重建 GRUB 菜单"

GRUB_CONF=/etc/default/grub
GRUB_BAK=/etc/default/grub.chenpi.bak

# 改系统配置前先备份。只备份一次：重复跑不覆盖最早那份干净版本。
if [ ! -f "$GRUB_BAK" ]; then
    as_root cp -a "$GRUB_CONF" "$GRUB_BAK"
    success "已备份 GRUB 配置 → $GRUB_BAK"
else
    log "备份已存在，保持不动：$GRUB_BAK"
fi

# GRUB_DISABLE_OS_PROBER 的含义：
#   true 或没写 → grub-mkconfig 不调 os-prober，菜单里就没有 Windows
#   false       → 会调，Windows 才会出现在菜单里
if grep -qE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=' "$GRUB_CONF"; then
    if grep -qE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=("false"|false)' "$GRUB_CONF"; then
        log "GRUB_DISABLE_OS_PROBER 已经是 false，不用改"
    else
        as_root sed -i -E 's|^[[:space:]]*GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|' "$GRUB_CONF"
        success "已把 GRUB_DISABLE_OS_PROBER 改成 false"
    fi
elif grep -qE '^[[:space:]]*#[[:space:]]*GRUB_DISABLE_OS_PROBER=' "$GRUB_CONF"; then
    # 被注释掉的情况：直接取消注释并补上 false。
    # 比「注释留着再追加一行」干净，同一个键出现两次以后一眼看去容易看混。
    as_root sed -i -E 's|^[[:space:]]*#[[:space:]]*GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|' "$GRUB_CONF"
    success "已取消注释并把该键设为 false"
else
    printf '%s\n' 'GRUB_DISABLE_OS_PROBER=false' | as_root tee -a "$GRUB_CONF" >/dev/null
    success "已追加 GRUB_DISABLE_OS_PROBER=false"
fi

# 幂等校验：这个键最终只应该出现一次（注释不算）
GRUB_KEY_LINES="$(grep -cE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=' "$GRUB_CONF" || true)"
info_kv "配置行数" "$GRUB_KEY_LINES" "正常应为 1"

# 重建 grub.cfg 才会把 Windows 条目真正写进菜单。
# 强制 LANG=en_US.UTF-8：某些非 UTF-8 环境下 grub-mkconfig 会告警甚至中断。
if [ -d /boot/grub ]; then
    log "重建 GRUB 配置（/boot/grub/grub.cfg）"
    if as_root env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg; then
        success "GRUB 重新生成完成"
    else
        # 不当作致命错误：配置已经改对了，install.sh 收尾还会再重建一次
        warn "grub-mkconfig 失败，看上面的输出；改好的配置和备份都在，重跑本模块即可"
    fi
else
    warn "没有 /boot/grub 目录，跳过重建（配置已写好，下次 grub 更新时会生效）"
fi

# ------------------------------------------------------------------------------
# 收尾
# ------------------------------------------------------------------------------
section "02c 完成" "双系统引导"
success "Windows 已加入 GRUB 探测范围"
log "重启后 GRUB 菜单里应该多出 Windows 项（有时在 Other options 子菜单里）"
info_kv "备份" "$GRUB_BAK" "还原：sudo cp 备份回 /etc/default/grub，再 sudo grub-mkconfig -o /boot/grub/grub.cfg"
