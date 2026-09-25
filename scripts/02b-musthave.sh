#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 02b-musthave.sh — 必需品：装完这些，系统才算「能用」
#
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/02b-musthave.sh（AGPL-3.0）。
# 和参考版的区别：
#   1. 不调 check_root（本仓库约定：普通用户跑，改系统的地方走 as_root，不强制 root）
#   2. 不写 /etc/sudoers.d 临时免密文件（as_root 自己会调 sudo）
#   3. 装包统一用 pac_install / aur_install，自动登记到装后对账清单
#   4. 去掉他的 [shorin-arch] 私有源、他的 fcitx5 魔改包、桌面变体相关内容
#   5. 日志变量统一叫 LOG_FILE；不再往 /tmp 写「安装用户」标记文件
#
# 顺序：音频 → 输入法 → 蓝牙 → 电源 → 常用工具 → pacman 外观 → Flatpak
#
# 注：Btrfs 快照那一套（snapper / grub-btrfs / inotify-tools / grub-btrfsd）由必装的
#     00-btrfs-init.sh 负责，本模块不重复做 —— 两个模块抢同一件事只会互相打架；
#     连 btrfs-assistant 这种 GUI，那边也明确说了留给用户自己决定。
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. 前置检查
# ------------------------------------------------------------------------------
section "02b · 准备" "环境确认"

# TARGET_USER / TARGET_HOME / RUN_AS_ROOT 由 install.sh 检测好并 export。
# 本模块不建用户，只做检查，避免 as_user 里拿到空值去 runuser 造成莫名其妙的报错。
if [ -z "${TARGET_USER:-}" ] || [ -z "${TARGET_HOME:-}" ]; then
    error "TARGET_USER / TARGET_HOME 没设置，请通过 install.sh 运行本模块"
    exit 1
fi

info_kv "目标用户" "$TARGET_USER" "$TARGET_HOME"
info_kv "仓库根目录" "$REPO_ROOT"

# ------------------------------------------------------------------------------
# （参考项目的第 1 步是「Btrfs 快照工具 + GRUB 快照菜单」，本仓库不在这里做：
#   snapper / grub-btrfs / inotify-tools / grub-btrfsd / GRUB 记忆启动项
#   全部由必装的 00-btrfs-init.sh 处理，重复做只会互相打架。
#   这里直接进音频。）
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 1. 音频：固件 + PipeWire
# ------------------------------------------------------------------------------
section "02b · 步骤 1/7" "音频固件与 PipeWire 音频栈"

# sof-firmware 是新一代笔记本内置声卡的固件，缺了的话声卡只剩 dummy 输出（没声音）
log "装音频固件"
pac_install sof-firmware alsa-ucm-conf alsa-firmware || true

# PipeWire 是现在的标准音频服务：wireplumber 管设备策略，pipewire-pulse 兼容老客户端
log "装 PipeWire 音频栈"
pac_install pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack || true

# 32 位库：Steam / Wine 里的 32 位程序要出声得靠它（需要 multilib 源，没有就跳过）
if pacman -Si lib32-pipewire >/dev/null 2>&1; then
    pac_install lib32-pipewire || true
else
    log "源里没有 lib32-pipewire（多半没开 multilib），跳过 32 位音频库"
fi

# --global：给所有用户启用这套用户级服务，免得每个账号再手动 systemctl --user enable
as_root systemctl --global enable pipewire pipewire-pulse wireplumber \
    || warn "PipeWire 用户服务全局启用失败，登录后手动 systemctl --user enable 一次"
success "音频栈就绪"

# ------------------------------------------------------------------------------
# 2. 输入法：Fcitx5 + Rime
# ------------------------------------------------------------------------------
section "02b · 步骤 2/7" "输入法（Fcitx5 + Rime）"

# 家目录配置里默认输入法就是 rime（.config/fcitx5/profile 里 DefaultIM=rime），
# 所以装 fcitx5 本体 + 各 GUI 工具箱（gtk/qt）+ rime 引擎。
# 注意：只用官方源里的稳定版 fcitx5，不装任何第三方「魔改补丁包」。
pac_install fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-rime || true

# librime-data 是 rime 的基础数据，各种方案都依赖
pac_install librime-data || true

# 雾凇拼音方案（rime-ice）在 AUR，属于可选增强：装不上不影响 fcitx5 本身可用
if has_pkg rime-ice-git; then
    log "rime-ice-git 已经装过了，跳过"
else
    log "补装雾凇拼音方案（AUR：rime-ice-git）"
    aur_install rime-ice-git || warn "rime-ice-git 没装上，之后可以自己用 yay -S 补"
fi

# GTK_IM_MODULE / QT_IM_MODULE 等环境变量由 dotfiles 里的 fish 配置负责，这里不重复写
success "输入法就绪（默认方案 rime，具体配置由 dotfiles 恢复）"

# ------------------------------------------------------------------------------
# 3. 蓝牙：先检测硬件，检测不到就不装
# ------------------------------------------------------------------------------
section "02b · 步骤 3/7" "蓝牙（按硬件决定装不装）"

# lsusb / lspci 可能还没装，先补齐检测工具
pac_install usbutils pciutils || true

# 四条线索任一命中就认为有蓝牙硬件：
#   1. USB 蓝牙模块（最常见）
#   2. 走 PCI 的蓝牙（多为 Wi-Fi 网卡集成）
#   3. 内核 rfkill 已经列出 bluetooth 设备
#   4. /sys/class/bluetooth 下有节点（有些固件不上报型号，只能靠这个）
BT_FOUND=0
if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qi bluetooth; then BT_FOUND=1; fi
if [ "$BT_FOUND" -eq 0 ] && command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -qi bluetooth; then BT_FOUND=1; fi
if [ "$BT_FOUND" -eq 0 ] && command -v rfkill >/dev/null 2>&1 && rfkill list bluetooth >/dev/null 2>&1; then BT_FOUND=1; fi
if [ "$BT_FOUND" -eq 0 ] && [ -d /sys/class/bluetooth ] && [ -n "$(ls -A /sys/class/bluetooth 2>/dev/null || true)" ]; then BT_FOUND=1; fi

if [ "$BT_FOUND" -eq 1 ]; then
    info_kv "蓝牙硬件" "检测到"
    # bluez 是协议栈本体，bluetui 是终端里的蓝牙管理界面（配 fish 用着顺手）
    pac_install bluez bluetui || true
    as_root systemctl enable --now bluetooth \
        || warn "bluetooth 服务启用失败，检查是不是被 rfkill 关掉了"
    success "蓝牙已启用"
else
    info_kv "蓝牙硬件" "未检测到"
    warn "没有蓝牙硬件，跳过 bluez（省得白拉一堆依赖）"
fi

# ------------------------------------------------------------------------------
# 4. 电源管理
# ------------------------------------------------------------------------------
section "02b · 步骤 4/7" "电源管理"

if has_pkg tlp; then
    # tlp 和 power-profiles-daemon 会抢同一套电源接口，同时装会互相打架
    warn "系统里已经有 tlp，跳装 power-profiles-daemon（两者不能共存）"
else
    pac_install power-profiles-daemon || true
    as_root systemctl enable --now power-profiles-daemon \
        || warn "power-profiles-daemon 启用失败"
fi
success "电源配置就绪（awob 的 power-profile 监听器依赖这个服务）"

# ------------------------------------------------------------------------------
# 5. 常用命令行工具（含 AMD 平台检测）
# ------------------------------------------------------------------------------
section "02b · 步骤 5/7" "常用命令行工具"

pac_install fastfetch gdu btop cmatrix lolcat sl || true

# btop 的 GPU 监控在 AMD 平台上要读 rocm-smi-lib 提供的库；
# Intel 走 sysfs、NVIDIA 走 nvidia-smi，都不需要它，所以只在 AMD 上装，省几百兆。
if command -v lscpu >/dev/null 2>&1 && lscpu 2>/dev/null | grep -qi 'amd'; then
    log "检测到 AMD CPU，补装 btop 的 GPU 监控依赖 rocm-smi-lib"
    pac_install rocm-smi-lib || true
else
    log "不是 AMD 平台，跳过 rocm-smi-lib"
fi
success "命令行工具就绪"

# ------------------------------------------------------------------------------
# 6. pacman 彩色输出（改 /etc/pacman.conf，改前备份）
# ------------------------------------------------------------------------------
section "02b · 步骤 6/7" "pacman 彩色输出"

PACMAN_CONF=/etc/pacman.conf
PACMAN_BAK=/etc/pacman.conf.chenpi.bak

if [ ! -f "$PACMAN_CONF" ]; then
    warn "找不到 $PACMAN_CONF，跳过"
else
    # 动系统配置前先备份。只备份一次：重复跑不要覆盖最早那份干净版本。
    if [ ! -f "$PACMAN_BAK" ]; then
        as_root cp -a "$PACMAN_CONF" "$PACMAN_BAK"
        success "已备份原配置 → $PACMAN_BAK"
    else
        log "备份已存在，保持不动：$PACMAN_BAK"
    fi

    # Color：让 pacman 输出带颜色（出错红、警告黄），不再一片惨白
    if grep -qE '^[[:space:]]*Color' "$PACMAN_CONF"; then
        log "Color 已经开着"
    elif grep -qE '^[[:space:]]*#[[:space:]]*Color' "$PACMAN_CONF"; then
        as_root sed -i -E 's|^[[:space:]]*#[[:space:]]*Color.*|Color|' "$PACMAN_CONF"
        success "已把 #Color 取消注释"
    else
        # 文件里压根没这行：插到 [options] 段后面，保证落在正确的段里
        as_root sed -i '/^\[options\]/a Color' "$PACMAN_CONF"
        success "已在 [options] 段插入 Color"
    fi

    # ILoveCandy：进度条变成吃豆人（纯好玩，不改功能）
    if grep -qE '^[[:space:]]*ILoveCandy' "$PACMAN_CONF"; then
        log "ILoveCandy 已经开着"
    elif grep -qE '^[[:space:]]*#[[:space:]]*ILoveCandy' "$PACMAN_CONF"; then
        as_root sed -i -E 's|^[[:space:]]*#[[:space:]]*ILoveCandy.*|ILoveCandy|' "$PACMAN_CONF"
        success "已把 #ILoveCandy 取消注释"
    else
        as_root sed -i '/^\[options\]/a ILoveCandy' "$PACMAN_CONF"
        success "已在 [options] 段插入 ILoveCandy"
    fi

    # 幂等校验：这两个关键字各留一行就够了（正常应该是 2 行）
    KEY_LINES="$(grep -cE '^[[:space:]]*(Color|ILoveCandy)[[:space:]]*$' "$PACMAN_CONF" || true)"
    info_kv "关键字行数" "$KEY_LINES" "正常应为 2"
fi

# ------------------------------------------------------------------------------
# 7. Flatpak
# ------------------------------------------------------------------------------
section "02b · 步骤 7/7" "Flatpak"

pac_install flatpak || true

if command -v flatpak >/dev/null 2>&1; then
    # 系统级加 flathub 源（单用户机器上等于给所有人用）
    as_root flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo \
        || warn "flathub 源添加失败（多半是网络），之后手动 flatpak remote-add 补上"
    success "Flatpak + flathub 就绪"

    # 国内直连 flathub 很慢，但换镜像影响面大（各镜像同步进度不一），
    # 所以这里只提示、不自动改，想换就照下面这条来。
    if [ "$(readlink -f /etc/localtime 2>/dev/null || true)" = "/usr/share/zoneinfo/Asia/Shanghai" ]; then
        info_kv "区域" "Asia/Shanghai" "国内环境"
        log "拉取慢的话可以换镜像：sudo flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub"
    fi
else
    warn "flatpak 没装成功，跳过源配置"
fi

# ------------------------------------------------------------------------------
# 收尾
# ------------------------------------------------------------------------------
section "02b 完成" "必需品与顺手配置"
success "音频 / 输入法 / 蓝牙 / 电源 / 常用工具 / pacman 外观 / Flatpak 处理完毕"
info_kv "日志" "${LOG_FILE:-}" ""
log "没装上的包都登记在 ${VERIFY_LIST:-}，05-verify.sh 会统一对账"
