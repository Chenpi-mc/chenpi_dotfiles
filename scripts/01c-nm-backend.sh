#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 主控已经 export 了这三个变量；兜底只是为了让本模块能单独跑（set -u 不炸）。
export RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER="${TARGET_USER:-$(id -un)}"
export TARGET_HOME="${TARGET_HOME:-$HOME}"

# ==============================================================================
# 01c-nm-backend.sh — 把 NetworkManager 的 Wi-Fi 后端换成 iwd（可选模块）
# 改写自 ref/shorin-arch-setup/scripts/01c-nm-backend.sh
#
# 这是个"锦上添花"的可选模块（install.sh 的 OPTIONAL_MENU 里默认不勾），
# 所以它的原则是：任何前提不满足都干净地 exit 0，绝不让主控记成失败。
#   - 没装 NetworkManager → 整块跳过，exit 0，不报错
#   - iwd 已装 + 后端已经是 iwd → 没活可干，说明一下然后 exit 0
#   - 只做了一半（装了 iwd 但后端没切 / 后端指向 iwd 但包没装）→ 把缺的那半补上
#
# 为什么换 iwd：iwd 只管 Wi-Fi，比 wpa_supplicant 轻、连接管理更省心，
# 台式机没无线的话这个模块没什么意义 —— 所以默认不选它是对的。
# ==============================================================================

require_arch
section "网络后端（可选）" "NetworkManager 的 Wi-Fi 后端 → iwd"

NM_CONF_DIR="/etc/NetworkManager/conf.d"
IWD_CONF="$NM_CONF_DIR/iwd.conf"
NM_BAK_DIR="/var/backups/chenpi-nm"

# ------------------------------------------------------------------------------
# 1. 没有 NetworkManager 就直接退出（不报错、不影响别的模块）
# ------------------------------------------------------------------------------
if ! has_pkg networkmanager && ! command -v NetworkManager >/dev/null 2>&1; then
    warn "系统里没有 NetworkManager，整个模块跳过（不需要 iwd 后端）"
    exit 0
fi
info_kv "NetworkManager" "已安装"

# ------------------------------------------------------------------------------
# 2. 看现状：iwd 装了没 / 后端是不是已经指到 iwd
# ------------------------------------------------------------------------------
IWD_PRESENT=0
if has_pkg iwd; then
    IWD_PRESENT=1
fi

# 后端可能写在 conf.d 下任何一个 .conf 里，全扫一遍（不只看 iwd.conf）
CONF_WITH_IWD=""
if [ -d "$NM_CONF_DIR" ]; then
    CONF_WITH_IWD="$(grep -rlE '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd' "$NM_CONF_DIR" 2>/dev/null || true)"
fi
CONF_WITH_IWD="$(printf '%s' "$CONF_WITH_IWD" | head -n 1)"

if [ "$IWD_PRESENT" -eq 1 ] && [ -n "$CONF_WITH_IWD" ]; then
    success "iwd 已安装，且 NetworkManager 后端已经是 iwd（$CONF_WITH_IWD）"
    log "没有需要做的事，跳过（重复跑本模块也不会再改任何东西）"
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. iwd 装不装
# ------------------------------------------------------------------------------
if [ "$IWD_PRESENT" -eq 1 ]; then
    success "iwd 已经装过了，不重复安装"
else
    log "安装 iwd（NetworkManager 的 Wi-Fi 后端实现）"
    pac_install iwd || true
    if has_pkg iwd; then
        IWD_PRESENT=1
        success "iwd 安装完成"
    else
        warn "iwd 没装上，后端没法切，本模块到此结束（其它模块不受影响）"
        exit 0
    fi
fi

# 说明：iwd 的 TUI 工具 impala 是可选的（看无线用），不装也不影响，想要自己装。
if ! command -v impala >/dev/null 2>&1; then
    log "提示：iwd 的交互式 TUI（impala）没有装，命令行用 iwctl 就够；想要界面可自行装 impala"
fi

# ------------------------------------------------------------------------------
# 4. 写后端配置
# ------------------------------------------------------------------------------
# conf.d 里的文件是按文件名排序依次读取的，后面读到的会覆盖前面的。
# 老的 wifi_backend.conf（w 开头）排在 iwd.conf（i 开头）后面，
# 留着就会把我们的设置又盖回去，所以先把它挪到备份目录（不直接删，方便回退）。
as_root mkdir -p "$NM_CONF_DIR"

if [ -f "$NM_CONF_DIR/wifi_backend.conf" ]; then
    if grep -qE '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd' "$NM_CONF_DIR/wifi_backend.conf"; then
        log "已存在 $NM_CONF_DIR/wifi_backend.conf，里面本来就是 iwd 后端，保留不动"
    else
        as_root mkdir -p "$NM_BAK_DIR"
        as_root mv "$NM_CONF_DIR/wifi_backend.conf" "$NM_BAK_DIR/wifi_backend.conf.$(date +%Y%m%d-%H%M%S)"
        warn "旧的 wifi_backend.conf 会覆盖 iwd.conf，已挪到 $NM_BAK_DIR/"
    fi
fi

if [ -f "$IWD_CONF" ] && grep -qE '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd' "$IWD_CONF"; then
    success "$IWD_CONF 里已经是 iwd 后端，不重复写"
    NEW_SWITCH=0
else
    log "写入 $IWD_CONF（[device] / wifi.backend=iwd）"
    printf '[device]\nwifi.backend=iwd\n' | as_root tee "$IWD_CONF" >/dev/null
    as_root chmod 0644 "$IWD_CONF"
    success "NetworkManager 后端配置已就位：$IWD_CONF"
    NEW_SWITCH=1
fi

# ------------------------------------------------------------------------------
# 5. 清掉旧后端的 Wi-Fi 连接（先备份，不清的话会出现"看得见连不上"）
# ------------------------------------------------------------------------------
# wpa_supplicant 时代 /etc/NetworkManager/system-connections/ 里存的连接，
# 换到 iwd 后端后用不了，留着只会让人困惑。
# 但那是用户的网络数据（含密码），不能直接删 —— 整目录备份后再清空。
if [ "$NEW_SWITCH" -eq 1 ]; then
    if [ -d /etc/NetworkManager/system-connections ]; then
        if [ -n "$(ls -A /etc/NetworkManager/system-connections 2>/dev/null || true)" ]; then
            as_root mkdir -p "$NM_BAK_DIR"
            as_root cp -a /etc/NetworkManager/system-connections \
                "$NM_BAK_DIR/system-connections.$(date +%Y%m%d-%H%M%S)"
            as_root find /etc/NetworkManager/system-connections -mindepth 1 -delete >/dev/null 2>&1 || true
            warn "旧的 Wi-Fi 连接已备份到 $NM_BAK_DIR/ 并清空：换后端后要重新输一次 Wi-Fi 密码"
        else
            log "system-connections 里没有旧连接，不用清理"
        fi
    else
        log "没有 system-connections 目录，跳过清理"
    fi
else
    log "后端配置没变（本来就是 iwd），跳过旧连接清理，避免误删你现在用的网络"
fi

# ------------------------------------------------------------------------------
# 6. 启用 iwd.service
# ------------------------------------------------------------------------------
# 启用（不是立刻 start）：NetworkManager 会按需通过 D-Bus 拉起 iwd，
# 开机自启能保证重启后无线马上可用。
log "启用 iwd.service（开机自启）"
if as_root systemctl enable iwd >/dev/null 2>&1; then
    success "iwd.service 已启用"
else
    warn "iwd.service 启用失败，重启后手动跑一次 systemctl enable iwd"
fi

# ------------------------------------------------------------------------------
# 7. 收尾
# ------------------------------------------------------------------------------
# 故意不重启 NetworkManager：现在重启会立刻断网（你可能正是靠网络在跑安装），
# 所以把生效时间放到重启之后。
log "不重启 NetworkManager（避免当场断网），重启机器后新后端生效"

section "01c 完成" "网络后端配置汇总"
info_kv "iwd" "已安装"
info_kv "后端配置" "$IWD_CONF"
info_kv "连接备份" "$NM_BAK_DIR" "换后端时清掉的旧 Wi-Fi 配置"
info_kv "生效时机" "重启后"
success "Wi-Fi 后端已切到 iwd（想回退：删掉 $IWD_CONF 并重启 NetworkManager）"
exit 0
