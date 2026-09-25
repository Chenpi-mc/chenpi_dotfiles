#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 03b-gpu-driver.sh — 显卡驱动（用 chwd 自动检测 + 安装）
#
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/03b-gpu-driver.sh（AGPL-3.0）。
# chwd 是 CachyOS 的硬件检测工具：认出显卡等 PCI 设备后自动装对应驱动
# （NVIDIA → nvidia-open-dkms / nvidia-dkms，AMD/Intel → mesa + vulkan）。
# 来源：先看官方源（CachyOS 的 cachyos 源里有），没有才从 AUR 装 chwd-arch-git。
# 和参考版的区别：不调 check_root（改系统走 as_root）、不写 /etc/sudoers.d 临时免密、
# 装包走 pac_install / aur_install 登记对账、chwd 装不上时给手动兜底包名。
# ==============================================================================

# 0. 前置检查
section "$(t "03b · 准备" "03b · Prep")" "$(t "环境确认" "Environment check")"

# 纯官方源装 chwd 时用不到用户信息，但从 AUR 装就要（makepkg 不能以 root 跑）。
# 这里只提醒不退出 —— 免得仅因为变量缺失就把官方源这条正路也堵死。
if [ -z "${TARGET_USER:-}" ]; then
    warn "$(t "TARGET_USER 没设置（正常应由 install.sh 导出）；万一要走 AUR 编译可能失败" "TARGET_USER unset; AUR build may fail")"
fi
info_kv "$(t "内核" "Kernel")" "$(uname -r)" "$(t "DKMS 驱动要跟内核匹配" "DKMS drivers must match the kernel")"
info_kv "$(t "仓库根目录" "Repo root")" "$REPO_ROOT"

# lspci 来自 pciutils，判断显卡型号靠它
if ! command -v lspci >/dev/null 2>&1; then
    log "$(t "先装 pciutils（lspci 用来看显卡型号）" "Installing pciutils (for lspci)")"
    pac_install pciutils || true
fi

if ! command -v lspci >/dev/null 2>&1; then
    error "$(t "拿不到 lspci，没法判断显卡类型" "No lspci, cannot detect GPU type")"
    log "$(t "缺 pciutils，装完重跑" "missing pciutils, install and rerun")"
    exit 1
fi

# 1. 检测显卡类型
section "$(t "03b · 步骤 1/3" "03b · Step 1/3")" "$(t "检测显卡" "Detect GPUs")"

GPU_LINES="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"

if [ -z "$GPU_LINES" ]; then
    warn "$(t "lspci 没报出任何显示设备，有点反常（虚拟机里属正常）" "No display devices from lspci (normal in a VM)")"
else
    log "$(t "检测到的显示设备：" "Display devices found:")"
    while IFS= read -r gpu_line; do
        if [ -n "$gpu_line" ]; then
            log "  $gpu_line"
        fi
    done <<< "$GPU_LINES"
fi

# 三家分别判断（用 if 而不是 `grep && VAR=1`：后者在没匹配时会让 set -e 直接退出脚本）
IS_NVIDIA=0
IS_AMD=0
IS_INTEL=0
if grep -qi 'nvidia' <<< "$GPU_LINES"; then IS_NVIDIA=1; fi
if grep -qiE 'advanced micro devices|amd/ati|radeon' <<< "$GPU_LINES"; then IS_AMD=1; fi
if grep -qi 'intel' <<< "$GPU_LINES"; then IS_INTEL=1; fi

if [ "$IS_NVIDIA" -eq 1 ]; then info_kv "NVIDIA" "$(t "检测到" "found")" "$(t "专用驱动" "proprietary")"; fi
if [ "$IS_AMD" -eq 1 ]; then info_kv "AMD" "$(t "检测到" "found")" "$(t "开源 amdgpu" "open amdgpu")"; fi
if [ "$IS_INTEL" -eq 1 ]; then info_kv "Intel" "$(t "检测到" "found")" "$(t "开源 i915/xe" "open i915/xe")"; fi

if [ $((IS_NVIDIA + IS_AMD + IS_INTEL)) -eq 0 ]; then
    warn "$(t "没认出显卡型号，chwd 可能失败" "GPU model not detected, chwd may fail")"
fi

# 双显卡（NVIDIA + 核显）是笔记本常态：驱动交给 chwd，这里只说清切换方式
if [ "$IS_NVIDIA" -eq 1 ] && { [ "$IS_AMD" -eq 1 ] || [ "$IS_INTEL" -eq 1 ]; }; then
    info_kv "$(t "双显卡" "Hybrid GPU")" "$(t "是" "yes")" "$(t "NVIDIA + 核显" "NVIDIA + iGPU")"
    log "$(t "默认走核显省电，要跑独显的程序前面加 prime-run" "iGPU by default; prefix heavy apps with prime-run")"
    log "$(t "NVIDIA 在 Wayland 下需要 nvidia_drm.modeset=1（chwd 一般会配好）" "Wayland NVIDIA needs nvidia_drm.modeset=1 (chwd sets it)")"
fi

# 顺手列一下已经装了的显卡相关包，方便对比 chwd 装完前后
INSTALLED_GPU_PKGS="$(pacman -Qq 2>/dev/null | grep -E '^(nvidia|nvidia-open|mesa$|mesa-|vulkan-(intel|radeon)|xf86-video-(amdgpu|intel)|lib32-(mesa|nvidia-utils))' | tr '\n' ' ' || true)"
info_kv "$(t "已装相关包" "Installed pkgs")" "${INSTALLED_GPU_PKGS:-$(t "无" "none")}" ""

# 2. 安装 chwd
section "$(t "03b · 步骤 2/3" "03b · Step 2/3")" "$(t "安装 chwd（硬件检测工具）" "Install chwd")"

# 已经装过就别再动：chwd 自己会跟着系统升级走
if command -v chwd >/dev/null 2>&1 || has_pkg chwd; then
    success "$(t "chwd 已经装过了，跳过" "chwd already installed, skipping")"
else
    # 优先官方源：能跟着 pacman 一起升级，也不用现场编译
    # （chwd 在 CachyOS 的 cachyos 源里；纯 Arch 官方仓库没有，那时才走 AUR。）
    if pacman -Si chwd >/dev/null 2>&1; then
        log "$(t "官方源里有 chwd，直接用 pacman 装" "chwd is in the official repo, installing")"
        pac_install chwd || true
    else
        log "$(t "官方源里没有 chwd，改从 AUR 装 chwd-arch-git" "Not in repo, installing chwd-arch-git from AUR")"
        aur_install chwd-arch-git || true
    fi
fi

# 再确认一次，决定后面到底跑不跑自动配置
CHWD_OK=0
if command -v chwd >/dev/null 2>&1 || has_pkg chwd; then
    CHWD_OK=1
else
    warn "$(t "chwd 没装上（AUR 编译失败、网络不好都可能）" "chwd not installed (AUR build or network)")"
    log "$(t "不影响系统使用：看下面「手动兜底」照装，装好后重跑" "Not blocking: use the fallbacks below, then rerun")"
fi

# 3. 让 chwd 自动装驱动
section "$(t "03b · 步骤 3/3" "03b · Step 3/3")" "$(t "自动配置显卡驱动" "Auto-configure GPU drivers")"

if [ "$CHWD_OK" -eq 1 ]; then
    # --list 只列出能识别的配置，只读、不装东西；老版本可能没这个参数，失败也无所谓
    log "$(t "chwd 能识别的硬件配置（只读）：" "Hardware profiles chwd sees (read-only):")"
    as_root chwd --list 2>/dev/null \
        || warn "$(t "chwd --list 没输出（老版本可能没这参数，不影响下一步）" "no chwd --list output (old version? not blocking)")"

    # -a / --autoconfigure：给所有匹配到的 PCI 设备自动装驱动；
    # NVIDIA 的情况下它会顺带处理 initramfs 和必要内核参数。
    log "$(t "开始自动配置（会装驱动包，可能要几分钟）" "Auto-configuring (installs drivers, may take minutes)")"
    if as_root chwd -a; then
        success "$(t "chwd 自动配置完成" "chwd autoconfigure done")"
    else
        warn "$(t "chwd 报错退出，看上面的输出" "chwd exited with an error, see output above")"
        log "$(t "可以自己看列表再挑着装：sudo chwd -l 然后 sudo chwd -i <配置名>" "Or pick manually: sudo chwd -l, then sudo chwd -i <profile>")"
    fi
else
    warn "$(t "没有 chwd，跳过自动装驱动" "No chwd, skipping automatic driver install")"
fi

# 当前绑定到显卡上的内核驱动（只读检查，最能看出驱动到底生效没有）
log "$(t "当前显卡绑定的内核驱动：" "Kernel driver bound to the GPU:")"
if command -v lspci >/dev/null 2>&1; then
    lspci -k 2>/dev/null | grep -A2 -Ei 'vga|3d|display' || true
fi

# 收尾：按检测结果给手动兜底方案
section "$(t "03b 完成" "03b Done")" "$(t "结果与手动兜底" "Result and fallbacks")"

if [ "$IS_INTEL" -eq 1 ]; then
    info_kv "$(t "Intel 核显" "Intel iGPU")" "mesa vulkan-intel" "$(t "一般随系统已装好" "usually already installed")"
fi
if [ "$IS_AMD" -eq 1 ]; then
    info_kv "$(t "AMD 显卡" "AMD GPU")" "mesa vulkan-radeon libva-mesa-driver" "$(t "一般随系统已装好" "usually already installed")"
fi
if [ "$IS_NVIDIA" -eq 1 ]; then
    info_kv "$(t "NVIDIA 独显" "NVIDIA dGPU")" "nvidia-open-dkms nvidia-utils" "$(t "新卡（Turing 及以后）" "new cards (Turing+)")"
    info_kv "$(t "NVIDIA 老卡" "NVIDIA legacy")" "nvidia-dkms" "$(t "GTX 10 系及更早" "GTX 10 series and older")"
fi

log "$(t "装完建议重启再验证：NVIDIA 用 nvidia-smi，通用用 glxinfo -B" "Reboot to verify: nvidia-smi or glxinfo -B")"
log "$(t "niri 黑屏先查报错：journalctl -b -p err | grep -iE 'nvidia|amdgpu|i915|xe'" "niri black screen? check journalctl -b -p err")"
info_kv "$(t "日志" "Log")" "${LOG_FILE:-}" ""
