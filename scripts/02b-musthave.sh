#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 02b-musthave.sh — 必需品：装完这些，系统才算「能用」
#
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/02b-musthave.sh（AGPL-3.0）。
# 和参考版的区别：不调 check_root（普通用户跑，改系统走 as_root）、装包统一走
# pac_install / aur_install 并登记对账、不碰他的私有源和魔改包。
# Btrfs 快照那套（snapper / grub-btrfs / grub-btrfsd）归 00-btrfs-init.sh，这里不重复。
# ==============================================================================

# 0. 前置检查
log "$(t "02b · 准备" "02b · Prep") — $(t "环境确认" "Environment check")"

# TARGET_USER / TARGET_HOME / RUN_AS_ROOT 由 install.sh 检测并 export。
# 这里只检查不重建：as_user 拿到空值会报莫名其妙的错。
if [ -z "${TARGET_USER:-}" ] || [ -z "${TARGET_HOME:-}" ]; then
    error "$(t "TARGET_USER / TARGET_HOME 没设置，请通过 install.sh 运行" "TARGET_USER / TARGET_HOME unset; run via install.sh")"
    exit 1
fi

log "$(t "目标用户" "Target user"): $TARGET_USER ($TARGET_HOME)"
log "$(t "仓库根目录" "Repo root"): $REPO_ROOT"

# 1. 音频：固件 + PipeWire
log "$(t "02b · 步骤 1/7" "02b · Step 1/7") — $(t "音频固件与 PipeWire" "Audio firmware & PipeWire")"

# sof-firmware 缺了的话声卡只剩 dummy 输出（没声音）
log "$(t "装音频固件" "Installing audio firmware")"
pac_install sof-firmware alsa-ucm-conf alsa-firmware || true

log "$(t "装 PipeWire 音频栈" "Installing PipeWire stack")"
pac_install pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack || true

# 32 位输出（Steam / Wine）靠它，需要 multilib 源，没有就跳过
if pacman -Si lib32-pipewire >/dev/null 2>&1; then
    pac_install lib32-pipewire || true
else
    log "$(t "没开 multilib，跳过 32 位音频库" "multilib disabled, skipping 32-bit audio")"
fi

# --global：给所有用户启用，省得每个账号再手动 systemctl --user enable
as_root systemctl --global enable pipewire pipewire-pulse wireplumber \
    || warn "$(t "PipeWire 用户服务启用失败，登录后手动 enable" "PipeWire user services failed; enable them after login")"
success "$(t "音频栈就绪" "Audio stack ready")"

# 2. 输入法：Fcitx5 + Rime
log "$(t "02b · 步骤 2/7" "02b · Step 2/7") — $(t "输入法（Fcitx5 + Rime）" "Input method (Fcitx5 + Rime)")"

# 家目录配置里默认输入法就是 rime（.config/fcitx5/profile），所以装本体 + rime 引擎。
# 只用官方源的稳定版，不装第三方魔改补丁包。
pac_install fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-rime || true

# librime-data 是 rime 的基础数据，各方案都依赖
pac_install librime-data || true

# 雾凇拼音（AUR）是可选增强，装不上不影响 fcitx5 本身
if has_pkg rime-ice-git; then
    log "$(t "rime-ice-git 已装，跳过" "rime-ice-git already installed")"
else
    log "$(t "补装雾凇拼音（AUR）" "Installing rime-ice (AUR)")"
    aur_install rime-ice-git || warn "$(t "rime-ice-git 没装上，可稍后 yay -S 补" "rime-ice-git failed; install later with yay -S")"
fi

# GTK_IM_MODULE / QT_IM_MODULE 由 dotfiles 里的 fish 配置负责，这里不重复写
success "$(t "输入法就绪（方案 rime）" "Input method ready (rime)")"

# 3. 蓝牙：检测不到硬件就不装
log "$(t "02b · 步骤 3/7" "02b · Step 3/7") — $(t "蓝牙（按硬件决定）" "Bluetooth (if present)")"

# lsusb / lspci 可能还没装，先补齐检测工具
pac_install usbutils pciutils || true

# 四条线索任一命中就算有蓝牙，检测逻辑保持原样：
# USB 模块、PCI 蓝牙、rfkill 列出 bluetooth、/sys/class/bluetooth 有节点
# （有些固件不上报型号，只能靠最后一条）
BT_FOUND=0
if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qi bluetooth; then BT_FOUND=1; fi
if [ "$BT_FOUND" -eq 0 ] && command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi bluetooth; then BT_FOUND=1; fi
if [ "$BT_FOUND" -eq 0 ] && command -v rfkill >/dev/null 2>&1 && rfkill list bluetooth >/dev/null 2>&1; then BT_FOUND=1; fi
if [ "$BT_FOUND" -eq 0 ] && [ -d /sys/class/bluetooth ] && [ -n "$(ls -A /sys/class/bluetooth 2>/dev/null || true)" ]; then BT_FOUND=1; fi

if [ "$BT_FOUND" -eq 1 ]; then
    info_kv "$(t "蓝牙硬件" "Bluetooth")" "$(t "检测到" "found")"
    # bluez 是协议栈本体，bluetui 是终端管理界面
    pac_install bluez bluetui || true
    as_root systemctl enable --now bluetooth \
        || warn "$(t "bluetooth 服务启用失败，看看是不是被 rfkill 关了" "bluetooth enable failed; check rfkill")"
    success "$(t "蓝牙已启用" "Bluetooth enabled")"
else
    info_kv "$(t "蓝牙硬件" "Bluetooth")" "$(t "未检测到" "not found")"
    warn "$(t "没蓝牙硬件，跳过 bluez" "No bluetooth hardware, skipping bluez")"
fi

# 4. 电源管理
log "$(t "02b · 步骤 4/7" "02b · Step 4/7") — $(t "电源管理" "Power management")"

if has_pkg tlp; then
    # tlp 和 power-profiles-daemon 抢同一套电源接口，不能共存
    warn "$(t "已有 tlp，跳装 power-profiles-daemon" "tlp present, skipping power-profiles-daemon")"
else
    pac_install power-profiles-daemon || true
    as_root systemctl enable --now power-profiles-daemon \
        || warn "$(t "power-profiles-daemon 启用失败" "power-profiles-daemon enable failed")"
fi
success "$(t "电源配置就绪（awob 的监听器依赖它）" "Power ready (awob listeners need it)")"

# 5. 常用命令行工具（含 AMD 平台检测）
log "$(t "02b · 步骤 5/7" "02b · Step 5/7") — $(t "常用命令行工具" "Command-line tools")"

pac_install fastfetch gdu btop cmatrix lolcat sl || true

# btop 的 GPU 监控只有 AMD 需要 rocm-smi-lib：Intel 走 sysfs、NVIDIA 走 nvidia-smi
if command -v lscpu >/dev/null 2>&1 && lscpu 2>/dev/null | grep -qi 'amd'; then
    log "$(t "AMD 平台，补装 rocm-smi-lib" "AMD platform, installing rocm-smi-lib")"
    pac_install rocm-smi-lib || true
else
    log "$(t "非 AMD 平台，跳过 rocm-smi-lib" "Not AMD, skipping rocm-smi-lib")"
fi
success "$(t "命令行工具就绪" "CLI tools ready")"

# 6. pacman 彩色输出（改 /etc/pacman.conf，改前备份）
log "$(t "02b · 步骤 6/7" "02b · Step 6/7") — $(t "pacman 彩色输出" "pacman color output")"

PACMAN_CONF=/etc/pacman.conf
PACMAN_BAK=/etc/pacman.conf.chenpi.bak

if [ ! -f "$PACMAN_CONF" ]; then
    warn "$(t "找不到 $PACMAN_CONF，跳过" "no $PACMAN_CONF, skipping")"
else
    # 只备份一次：重复跑别覆盖最早那份干净版本
    if [ ! -f "$PACMAN_BAK" ]; then
        as_root cp -a "$PACMAN_CONF" "$PACMAN_BAK"
        success "$(t "已备份原配置 → $PACMAN_BAK" "Backed up original to $PACMAN_BAK")"
    else
        log "$(t "备份已存在，保持不动：$PACMAN_BAK" "Backup exists, kept: $PACMAN_BAK")"
    fi

    if grep -qE '^[[:space:]]*Color' "$PACMAN_CONF"; then
        log "$(t "Color 已经开着" "Color already on")"
    elif grep -qE '^[[:space:]]*#[[:space:]]*Color' "$PACMAN_CONF"; then
        as_root sed -i -E 's|^[[:space:]]*#[[:space:]]*Color.*|Color|' "$PACMAN_CONF"
        success "$(t "已取消 #Color 注释" "Uncommented #Color")"
    else
        # 文件里没这行：插到 [options] 段后面，保证落在正确的段里
        as_root sed -i '/^\[options\]/a Color' "$PACMAN_CONF"
        success "$(t "已在 [options] 段插入 Color" "Inserted Color into [options]")"
    fi

    if grep -qE '^[[:space:]]*ILoveCandy' "$PACMAN_CONF"; then
        log "$(t "ILoveCandy 已经开着" "ILoveCandy already on")"
    elif grep -qE '^[[:space:]]*#[[:space:]]*ILoveCandy' "$PACMAN_CONF"; then
        as_root sed -i -E 's|^[[:space:]]*#[[:space:]]*ILoveCandy.*|ILoveCandy|' "$PACMAN_CONF"
        success "$(t "已取消 #ILoveCandy 注释" "Uncommented #ILoveCandy")"
    else
        as_root sed -i '/^\[options\]/a ILoveCandy' "$PACMAN_CONF"
        success "$(t "已在 [options] 段插入 ILoveCandy" "Inserted ILoveCandy into [options]")"
    fi

    # 幂等校验：这两个关键字各留一行就够（正常应该 2 行）
    KEY_LINES="$(grep -cE '^[[:space:]]*(Color|ILoveCandy)[[:space:]]*$' "$PACMAN_CONF" || true)"
    log "$(t "关键字行数" "Key lines"): $KEY_LINES（$(t "正常应为 2" "expected 2")）"
fi

# 7. Flatpak
log "$(t "02b · 步骤 7/7" "02b · Step 7/7") — Flatpak"

pac_install flatpak || true

if command -v flatpak >/dev/null 2>&1; then
    # 系统级加源：单用户机器上等于给所有人用
    as_root flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo \
        || warn "$(t "flathub 源添加失败（多半是网络），之后手动补上" "flathub remote-add failed (network?); add it manually")"
    success "$(t "Flatpak + flathub 就绪" "Flatpak + flathub ready")"

    # 国内直连 flathub 慢，但换镜像影响面大（各镜像同步进度不一），只提示不自动改
    if [ "$(readlink -f /etc/localtime 2>/dev/null || true)" = "/usr/share/zoneinfo/Asia/Shanghai" ]; then
        log "$(t "区域" "Region"): Asia/Shanghai（$(t "国内环境" "China")）"
        log "$(t "拉取慢可换镜像：flatpak remote-modify flathub --url=<sjtu 镜像>" "Slow? flatpak remote-modify flathub --url=<sjtu mirror>")"
    fi
else
    warn "$(t "flatpak 没装成功，跳过源配置" "flatpak missing, skipping remote setup")"
fi

# 收尾
log "$(t "02b 完成" "02b Done") — $(t "必需品与顺手配置" "Must-haves and extras")"
success "$(t "音频 / 输入法 / 蓝牙 / 电源 / 工具 / pacman 外观 / Flatpak 都处理完了" "Audio / IME / BT / power / tools / pacman / Flatpak done")"
info_kv "$(t "日志" "Log")" "${LOG_FILE:-}" ""
log "$(t "没装上的包都登记在 ${VERIFY_LIST:-}，05-verify.sh 统一对账" "Failed pkgs logged in ${VERIFY_LIST:-} for 05-verify.sh")"
