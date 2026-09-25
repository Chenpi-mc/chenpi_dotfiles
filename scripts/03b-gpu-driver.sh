#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 03b-gpu-driver.sh — 显卡驱动（用 chwd 自动检测 + 安装）
#
# 改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/03b-gpu-driver.sh（AGPL-3.0）。
#
# chwd 是 CachyOS 出的硬件检测工具：认出显卡等 PCI 设备后自动装对应驱动包
# （NVIDIA → nvidia-open-dkms / nvidia-dkms，AMD/Intel → mesa + vulkan 相关）。
# 装哪里来：先看官方源（CachyOS 的 cachyos 源里有 chwd），
#           官方源没有再从 AUR 装 chwd-arch-git。
#
# 和参考版的区别：
#   1. 不调 check_root（改系统走 as_root），也不写 /etc/sudoers.d 临时免密文件
#   2. 装包走 pac_install / aur_install，自动登记装后对账
#   3. 装之前先用 lspci 判断显卡类型并告诉用户，让「自动装驱动」这件事有据可查
#   4. chwd 装不上时不硬撑，给出按显卡类型的手动兜底包名
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. 前置检查
# ------------------------------------------------------------------------------
section "03b · 准备" "环境确认"

# 纯官方源装 chwd 时用不到用户信息；但从 AUR 装就要用到（makepkg 不能以 root 跑），
# 这里只提醒不退出 —— 免得仅因为变量缺失就把官方源这条正路也堵死。
if [ -z "${TARGET_USER:-}" ]; then
    warn "TARGET_USER 没设置（正常应由 install.sh 导出）；万一要走 AUR 编译可能失败"
fi
info_kv "内核" "$(uname -r)" "DKMS 驱动要跟内核匹配"
info_kv "仓库根目录" "$REPO_ROOT"

# lspci 来自 pciutils，判断显卡型号靠它
if ! command -v lspci >/dev/null 2>&1; then
    log "先装 pciutils（lspci 用来看显卡型号）"
    pac_install pciutils || true
fi

if ! command -v lspci >/dev/null 2>&1; then
    error "拿不到 lspci，没法判断显卡类型"
    log "手动装：sudo pacman -S --needed pciutils，然后重跑本模块"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. 检测显卡类型
# ------------------------------------------------------------------------------
section "03b · 步骤 1/3" "检测显卡"

GPU_LINES="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"

if [ -z "$GPU_LINES" ]; then
    warn "lspci 没报出任何显示设备，有点反常（虚拟机里属正常）"
else
    log "检测到的显示设备："
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

if [ "$IS_NVIDIA" -eq 1 ]; then info_kv "NVIDIA" "检测到" "专用驱动"; fi
if [ "$IS_AMD" -eq 1 ]; then info_kv "AMD" "检测到" "开源 amdgpu"; fi
if [ "$IS_INTEL" -eq 1 ]; then info_kv "Intel" "检测到" "开源 i915/xe"; fi

if [ $((IS_NVIDIA + IS_AMD + IS_INTEL)) -eq 0 ]; then
    warn "NVIDIA / AMD / Intel 一个都没认出来，chwd 也可能认不出，后面失败属预料之中"
fi

# 双显卡（NVIDIA + 核显）是笔记本上的常态：NVIDIA 驱动由 chwd 装，
# 但要额外知道切换方式（prime-run）和 Wayland 下的注意事项。
if [ "$IS_NVIDIA" -eq 1 ] && { [ "$IS_AMD" -eq 1 ] || [ "$IS_INTEL" -eq 1 ]; }; then
    info_kv "双显卡" "是" "NVIDIA + 核显"
    log "混合显卡机器：默认走核显省电，要跑独显的程序前面加 prime-run"
    log "NVIDIA 在 Wayland 下需要内核参数 nvidia_drm.modeset=1（CachyOS/chwd 一般会自己配好）"
fi

# 顺手列一下已经装了的显卡相关包，方便对比 chwd 装完前后
INSTALLED_GPU_PKGS="$(pacman -Qq 2>/dev/null | grep -E '^(nvidia|nvidia-open|mesa$|mesa-|vulkan-(intel|radeon)|xf86-video-(amdgpu|intel)|lib32-(mesa|nvidia-utils))' | tr '\n' ' ' || true)"
info_kv "已装相关包" "${INSTALLED_GPU_PKGS:-无}" ""

# ------------------------------------------------------------------------------
# 2. 安装 chwd
# ------------------------------------------------------------------------------
section "03b · 步骤 2/3" "安装 chwd（硬件检测 / 驱动安装工具）"

# 已经装过就别再动：chwd 自己会跟着系统升级走
if command -v chwd >/dev/null 2>&1 || has_pkg chwd; then
    success "chwd 已经装过了，跳过安装"
else
    # 优先官方源：仓库里装的能跟着 pacman 一起升级，也不用现场编译。
    # （chwd 在 CachyOS 的 cachyos 源里；纯 Arch 官方仓库没有，那时才走 AUR。）
    if pacman -Si chwd >/dev/null 2>&1; then
        log "官方源里有 chwd，直接用 pacman 装"
        pac_install chwd || true
    else
        log "官方源里没有 chwd，改从 AUR 装 chwd-arch-git"
        aur_install chwd-arch-git || true
    fi
fi

# 再确认一次，决定后面到底跑不跑自动配置
CHWD_OK=0
if command -v chwd >/dev/null 2>&1 || has_pkg chwd; then
    CHWD_OK=1
else
    warn "chwd 没装上（AUR 编译失败、网络不好都可能）"
    log "不影响系统使用：看下面「手动兜底」的包名照装即可，装好后重跑本模块"
fi

# ------------------------------------------------------------------------------
# 3. 让 chwd 自动装驱动
# ------------------------------------------------------------------------------
section "03b · 步骤 3/3" "自动配置显卡驱动"

if [ "$CHWD_OK" -eq 1 ]; then
    # --list 只是列出能识别的配置，只读、不装东西，让用户看清 chwd 认出了什么。
    # 老版本可能没这个参数，失败了也无所谓。
    log "chwd 能识别的硬件配置（只读）："
    as_root chwd --list 2>/dev/null \
        || warn "chwd --list 没输出（老版本可能没这参数，不影响下一步）"

    # -a / --autoconfigure：给所有匹配到的 PCI 设备自动装驱动。
    # NVIDIA 的情况下它会顺带处理 initramfs 和必要内核参数。
    log "开始自动配置（会装驱动包，可能要几分钟）"
    if as_root chwd -a; then
        success "chwd 自动配置完成"
    else
        warn "chwd 报错退出，看上面的输出"
        log "可以自己看列表再挑着装：sudo chwd -l 然后 sudo chwd -i <配置名>"
    fi
else
    warn "没有 chwd，跳过自动装驱动"
fi

# 当前绑定到显卡上的内核驱动（只读检查，最能看出驱动到底生效没有）
log "当前显卡绑定的内核驱动："
if command -v lspci >/dev/null 2>&1; then
    lspci -k 2>/dev/null | grep -A2 -Ei 'vga|3d|display' || true
fi

# ------------------------------------------------------------------------------
# 收尾：按检测结果给手动兜底方案
# ------------------------------------------------------------------------------
section "03b 完成" "结果与手动兜底"

if [ "$IS_INTEL" -eq 1 ]; then
    info_kv "Intel 核显" "mesa vulkan-intel" "一般随系统已装好"
fi
if [ "$IS_AMD" -eq 1 ]; then
    info_kv "AMD 显卡" "mesa vulkan-radeon libva-mesa-driver" "一般随系统已装好"
fi
if [ "$IS_NVIDIA" -eq 1 ]; then
    info_kv "NVIDIA 独显" "nvidia-open-dkms nvidia-utils" "新卡（Turing 及以后）用这个"
    info_kv "NVIDIA 老卡" "nvidia-dkms" "GTX 10 系及更早"
fi

log "装完驱动建议重启一次再验证：NVIDIA 用 nvidia-smi，通用用 glxinfo -B（mesa-utils）"
log "如果 niri 黑屏/起不来，先查驱动有没有报错：journalctl -b -p err | grep -iE 'nvidia|amdgpu|i915|xe'"
info_kv "日志" "${LOG_FILE:-}" ""
