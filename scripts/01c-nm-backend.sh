#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 主控已经 export 了这三个变量；兜底只为让本模块单独跑时不被 set -u 炸掉。
export RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER="${TARGET_USER:-$(id -un)}"
export TARGET_HOME="${TARGET_HOME:-$HOME}"

# ==============================================================================
# 01c-nm-backend.sh — NetworkManager 的 Wi-Fi 后端换成 iwd（可选模块）
#
# 可选模块（默认不勾）：前提不满足就干净地 exit 0，绝不让主控记成失败。
# 换 iwd 是因为它只管 Wi-Fi，比 wpa_supplicant 轻、省心。
# ==============================================================================

require_arch
log "$(t "网络后端（可选）" "Network backend (optional)") — $(t "Wi-Fi 后端 → iwd" "Wi-Fi backend → iwd")"

NM_CONF_DIR="/etc/NetworkManager/conf.d"
IWD_CONF="$NM_CONF_DIR/iwd.conf"
NM_BAK_DIR="/var/backups/chenpi-nm"

# --- 1. 没有 NetworkManager 就干净退出 ---
if ! has_pkg networkmanager && ! command -v NetworkManager >/dev/null 2>&1; then
    warn "$(t "没有 NetworkManager，整块跳过" "NetworkManager not found, skipping")"
    exit 0
fi
log "$(t "NetworkManager" "NetworkManager"): $(t "已安装" "installed")"

# --- 2. 看现状：iwd 装了没 / 后端是不是已经指到 iwd ---
IWD_PRESENT=0
if has_pkg iwd; then
    IWD_PRESENT=1
fi

# 后端可能写在 conf.d 下任何一个 .conf 里，全扫一遍
CONF_WITH_IWD=""
if [ -d "$NM_CONF_DIR" ]; then
    CONF_WITH_IWD="$(grep -rlE '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd' "$NM_CONF_DIR" 2>/dev/null || true)"
fi
CONF_WITH_IWD="$(printf '%s' "$CONF_WITH_IWD" | head -n 1 || true)"

if [ "$IWD_PRESENT" -eq 1 ] && [ -n "$CONF_WITH_IWD" ]; then
    success "$(t "iwd 已装，后端已是 iwd（$CONF_WITH_IWD）" "iwd installed, backend already iwd ($CONF_WITH_IWD)")"
    log "$(t "没有需要做的事，跳过" "Nothing to do, skipping")"
    exit 0
fi

# --- 3. iwd 装不装 ---
if [ "$IWD_PRESENT" -eq 1 ]; then
    success "$(t "iwd 已经装过了，不重复安装" "iwd already installed")"
else
    log "$(t "安装 iwd（NetworkManager 的 Wi-Fi 后端）" "Installing iwd (the Wi-Fi backend)")"
    pac_install iwd || true
    if has_pkg iwd; then
        IWD_PRESENT=1
        success "$(t "iwd 安装完成" "iwd installed")"
    else
        warn "$(t "iwd 没装上，本模块到此结束（不影响其它模块）" "iwd install failed, stopping here (other modules unaffected)")"
        exit 0
    fi
fi

# impala 是 iwd 的可选 TUI，不装也能用，命令行 iwctl 就够
if ! command -v impala >/dev/null 2>&1; then
    log "$(t "没装 impala（iwd 的 TUI），要界面可自行装" "impala (iwd TUI) not installed; install it if you want a UI")"
fi

# --- 4. 写后端配置 ---
# conf.d 里的文件按文件名顺序读取，后面的覆盖前面的；wifi_backend.conf（w 开头）
# 排在 iwd.conf（i 开头）之后，留着会把我们的设置盖回去，所以挪到备份目录（不直接删）。
as_root mkdir -p "$NM_CONF_DIR"

if [ -f "$NM_CONF_DIR/wifi_backend.conf" ]; then
    if grep -qE '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd' "$NM_CONF_DIR/wifi_backend.conf"; then
        log "$(t "wifi_backend.conf 本来就是 iwd 后端，保留不动" "wifi_backend.conf already uses iwd, kept")"
    else
        as_root mkdir -p "$NM_BAK_DIR"
        as_root mv "$NM_CONF_DIR/wifi_backend.conf" "$NM_BAK_DIR/wifi_backend.conf.$(date +%Y%m%d-%H%M%S)"
        warn "$(t "旧的 wifi_backend.conf 会盖掉 iwd.conf，已挪到 $NM_BAK_DIR/" "Old wifi_backend.conf overrides iwd.conf; moved to $NM_BAK_DIR/")"
    fi
fi

if [ -f "$IWD_CONF" ] && grep -qE '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd' "$IWD_CONF"; then
    success "$(t "$IWD_CONF 里已经是 iwd 后端，不重复写" "$IWD_CONF already has the iwd backend")"
    NEW_SWITCH=0
else
    log "$(t "写入 $IWD_CONF（[device] / wifi.backend=iwd）" "Writing $IWD_CONF ([device] / wifi.backend=iwd)")"
    printf '[device]\nwifi.backend=iwd\n' | as_root tee "$IWD_CONF" >/dev/null
    as_root chmod 0644 "$IWD_CONF"
    success "$(t "后端配置已就位：$IWD_CONF" "Backend config in place: $IWD_CONF")"
    NEW_SWITCH=1
fi

# --- 5. 清掉旧后端的 Wi-Fi 连接（先备份，不清的话会"看得见连不上"） ---
# system-connections 里是用户的网络数据（含密码），换后端后用不了，但不能直接删：
# 整目录备份后再清空。
if [ "$NEW_SWITCH" -eq 1 ]; then
    if [ -d /etc/NetworkManager/system-connections ]; then
        if [ -n "$(ls -A /etc/NetworkManager/system-connections 2>/dev/null || true)" ]; then
            as_root mkdir -p "$NM_BAK_DIR"
            as_root cp -a /etc/NetworkManager/system-connections \
                "$NM_BAK_DIR/system-connections.$(date +%Y%m%d-%H%M%S)"
            as_root find /etc/NetworkManager/system-connections -mindepth 1 -delete >/dev/null 2>&1 || true
            warn "$(t "旧 Wi-Fi 连接已备份到 $NM_BAK_DIR/ 并清空：之后要重输一次密码" "Old Wi-Fi profiles backed up to $NM_BAK_DIR/ and cleared; re-enter the password later")"
        else
            log "$(t "system-connections 里没有旧连接，不用清理" "No old profiles in system-connections, nothing to clear")"
        fi
    else
        log "$(t "没有 system-connections 目录，跳过清理" "No system-connections dir, skipping")"
    fi
else
    log "$(t "后端没变，跳过清理以免误删在用的网络" "Backend unchanged; skipping cleanup to avoid deleting live networks")"
fi

# --- 6. 启用 iwd.service ---
# 只 enable 不 start：NetworkManager 会按需通过 D-Bus 拉起 iwd，
# enable 保证重启后无线马上可用。
log "$(t "启用 iwd.service（开机自启）" "Enabling iwd.service (start on boot)")"
if as_root systemctl enable iwd >/dev/null 2>&1; then
    success "$(t "iwd.service 已启用" "iwd.service enabled")"
else
    warn "$(t "启用失败，重启后手动跑 systemctl enable iwd" "Enable failed; run systemctl enable iwd manually")"
fi

# --- 7. 收尾 ---
# 故意不重启 NetworkManager：现在重启会当场断网（你可能正靠网络跑安装）
log "$(t "不重启 NetworkManager（避免当场断网），重启后新后端生效" "Not restarting NetworkManager (would drop the network); applies after reboot")"

log "$(t "01c 完成" "01c done") — $(t "网络后端汇总" "Summary")"
log "$(t "iwd" "iwd"): $(t "已安装" "installed")"
info_kv "$(t "后端配置" "Backend config")" "$IWD_CONF"
info_kv "$(t "连接备份" "Profile backup")" "$NM_BAK_DIR" "$(t "换后端时清掉的旧 Wi-Fi 配置" "old Wi-Fi profiles cleared on switch")"
info_kv "$(t "生效时机" "Takes effect")" "$(t "重启后" "after reboot")"
success "$(t "Wi-Fi 后端已切到 iwd（回退：删掉 $IWD_CONF 再重启 NetworkManager）" "Wi-Fi backend switched to iwd (rollback: delete $IWD_CONF, restart NetworkManager)")"
exit 0
