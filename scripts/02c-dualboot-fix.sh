#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 02c-dualboot-fix.sh — 让 GRUB 认出同一块硬盘上另一个分区里的 Windows
#
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/02c-dualboot-fix.sh（AGPL-3.0）。
# 背景：GRUB 从 2.06 起默认不再探测其他操作系统（GRUB_DISABLE_OS_PROBER 默认 true），
#       双系统机器装完 Arch 常常只剩 Arch 一个启动项。做法：装 os-prober、
#       显式设 GRUB_DISABLE_OS_PROBER=false、重建 grub.cfg。
# 不动分区表、不碰 Windows 的引导器，最坏情况只是没加启动项。
# ==============================================================================

# 0. 是不是 GRUB 启动
section "$(t "02c · 准备" "02c · Prep")" "$(t "检查引导器" "Bootloader check")"

if ! command -v grub-mkconfig >/dev/null 2>&1 || [ ! -f /etc/default/grub ]; then
    warn "$(t "没检测到 GRUB（grub-mkconfig 或 /etc/default/grub 缺失）" "No GRUB (grub-mkconfig or /etc/default/grub missing)")"
    log "$(t "用的是 systemd-boot 之类就不需要本模块，直接跳过" "Using systemd-boot? This module is not needed")"
    exit 0
fi
success "$(t "检测到 GRUB" "GRUB found")"

# 1. 装探测 Windows 需要的工具
section "$(t "02c · 步骤 1/3" "02c · Step 1/3")" "$(t "安装 os-prober" "Install os-prober")"

# os-prober 要挂载分区读引导文件，没有 NTFS / exFAT 支持就读不动 Windows 分区（会报挂载失败）
log "$(t "装 os-prober 和文件系统工具" "Installing os-prober and fs tools")"
pac_install os-prober ntfs-3g exfatprogs fuse3 || true

if ! command -v os-prober >/dev/null 2>&1; then
    warn "$(t "os-prober 没装上，后面的检测和 GRUB 重建都跳过" "os-prober missing, skipping detection and rebuild")"
    log "$(t "缺 os-prober，装完重跑" "missing os-prober, install and rerun")"
    exit 0
fi
success "$(t "os-prober 就绪" "os-prober ready")"

# 2. 扫描 Windows
section "$(t "02c · 步骤 2/3" "02c · Step 2/3")" "$(t "扫描其他操作系统" "Scan for other OSes")"

# os-prober 必须 root 跑（要挂载分区），可能要十几秒
log "$(t "开始扫描（有多个分区时会逐个挂载，慢一点正常）" "Scanning (mounts each partition, may take a while)")"
PROBE_OUT="$(as_root os-prober 2>/dev/null || true)"

if [ -n "$PROBE_OUT" ]; then
    log "$(t "os-prober 输出：" "os-prober output:")"
    while IFS= read -r probe_line; do
        if [ -n "$probe_line" ]; then
            log "  $probe_line"
        fi
    done <<< "$PROBE_OUT"
else
    warn "$(t "os-prober 什么都没探到" "os-prober found nothing")"
fi

if ! printf '%s\n' "$PROBE_OUT" | grep -qi 'windows'; then
    warn "$(t "没找到 Windows，不改 GRUB 配置，跳过（这不算失败）" "No Windows found; skipping (not an error)")"
    log "$(t "先查：Windows 快速启动没关？分区被 BitLocker 加密？" "Check: fast startup off? BitLocker encrypted?")"
    exit 0
fi
success "$(t "找到 Windows" "Windows found")"

# 3. 打开 os-prober + 重建 GRUB
section "$(t "02c · 步骤 3/3" "02c · Step 3/3")" "$(t "开启 os-prober 并重建菜单" "Enable os-prober and rebuild")"

GRUB_CONF=/etc/default/grub
GRUB_BAK=/etc/default/grub.chenpi.bak

# 改系统配置前先备份。只备份一次：重复跑不要覆盖最早那份干净版本。
if [ ! -f "$GRUB_BAK" ]; then
    as_root cp -a "$GRUB_CONF" "$GRUB_BAK"
    success "$(t "已备份 GRUB 配置 → $GRUB_BAK" "Backed up GRUB config to $GRUB_BAK")"
else
    log "$(t "备份已存在，保持不动：$GRUB_BAK" "Backup exists, kept: $GRUB_BAK")"
fi

# GRUB_DISABLE_OS_PROBER 设成 false，grub-mkconfig 才会调 os-prober、菜单里才有 Windows
if grep -qE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=' "$GRUB_CONF"; then
    if grep -qE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=("false"|false)' "$GRUB_CONF"; then
        log "$(t "已经是 false，不用改" "Already false, nothing to do")"
    else
        as_root sed -i -E 's|^[[:space:]]*GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|' "$GRUB_CONF"
        success "$(t "已改成 false" "Set to false")"
    fi
elif grep -qE '^[[:space:]]*#[[:space:]]*GRUB_DISABLE_OS_PROBER=' "$GRUB_CONF"; then
    # 被注释掉的情况：直接取消注释并补上 false。
    # 比「注释留着再追加一行」干净，同一个键出现两次以后一眼看去容易看混。
    as_root sed -i -E 's|^[[:space:]]*#[[:space:]]*GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|' "$GRUB_CONF"
    success "$(t "已取消注释并设为 false" "Uncommented and set to false")"
else
    printf '%s\n' 'GRUB_DISABLE_OS_PROBER=false' | as_root tee -a "$GRUB_CONF" >/dev/null
    success "$(t "已追加 GRUB_DISABLE_OS_PROBER=false" "Appended GRUB_DISABLE_OS_PROBER=false")"
fi

# 幂等校验：这个键最终只应该出现一次（注释不算）
GRUB_KEY_LINES="$(grep -cE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=' "$GRUB_CONF" || true)"
info_kv "$(t "配置行数" "Config lines")" "$GRUB_KEY_LINES" "$(t "正常应为 1" "expected 1")"

# 重建 grub.cfg 才会把 Windows 条目真正写进菜单。
# 强制 LANG=en_US.UTF-8：某些非 UTF-8 环境下 grub-mkconfig 会告警甚至中断。
if [ -d /boot/grub ]; then
    log "$(t "重建 GRUB 配置（/boot/grub/grub.cfg）" "Rebuilding /boot/grub/grub.cfg")"
    if as_root env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg; then
        success "$(t "GRUB 重新生成完成" "GRUB regenerated")"
    else
        # 不当作致命错误：配置已经改对了，install.sh 收尾还会再重建一次
        warn "$(t "grub-mkconfig 失败，改好的配置和备份都在，重跑本模块即可" "grub-mkconfig failed; config and backup kept, rerun")"
    fi
else
    warn "$(t "没有 /boot/grub 目录，跳过重建（配置已写好）" "No /boot/grub, skipping rebuild (config already set)")"
fi

# 收尾
section "$(t "02c 完成" "02c Done")" "$(t "双系统引导" "Dual-boot")"
success "$(t "Windows 已加入 GRUB 探测范围" "Windows added to GRUB probing")"
log "$(t "重启后菜单里多出 Windows 项（可能在 Other options 里）" "Reboot to see the Windows entry (maybe in Other options)")"
info_kv "$(t "备份" "Backup")" "$GRUB_BAK" "$(t "还原：cp 备份回 /etc/default/grub 后重建 grub.cfg" "Restore: cp backup back and rebuild grub.cfg")"
