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
# 01-mirrors.sh — 用 reflector 重排 pacman 镜像源
#
# 可选模块（默认不勾）。CHENPI_MIRRORS=skip 跳过；=force 不问直接重排。
# ==============================================================================

require_arch
log "$(t "镜像源优化" "Mirror optimization") — $(t "按实测速度重排 mirrorlist" "Re-rank mirrorlist by speed")"

MIRRORLIST="/etc/pacman.d/mirrorlist"
# 原始备份：只生成一次，之后绝不覆盖（想回到装机当天的状态就用它）
ORIG_BAK="/etc/pacman.d/mirrorlist.chenpi.orig"
# 上一版备份：每次真改动前覆盖一遍，方便只回退一步
PREV_BAK="/etc/pacman.d/mirrorlist.chenpi.prev"
MODE="${CHENPI_MIRRORS:-auto}"

# --- 0. 做还是不做 ---
case "$MODE" in
    skip)
        log "$(t "CHENPI_MIRRORS=skip：跳过，什么都不动" "CHENPI_MIRRORS=skip: skipping, nothing touched")"
        exit 0
        ;;
    force)
        log "$(t "CHENPI_MIRRORS=force：直接重排" "CHENPI_MIRRORS=force: re-ranking now")"
        ;;
    auto|*)
        if [ -t 0 ]; then
            # 模块是主动勾选的，默认就是做，只给一次反悔机会
            echo -ne "   ${H_CYAN}$(t "用 reflector 重排镜像源？（30 秒不答按继续）[Y/n] " "Re-rank mirrors with reflector? (yes in 30s) [Y/n] ")${NC}"
            read -t 30 -r _ans || true
            case "${_ans:-}" in
                [Nn]*) log "$(t "已取消，镜像源保持原样" "Cancelled, mirrorlist untouched")"; exit 0 ;;
            esac
        else
            log "$(t "非交互模式：按选择继续（跳过请设 CHENPI_MIRRORS=skip）" "Non-interactive: continuing (set CHENPI_MIRRORS=skip to skip)")"
        fi
        ;;
esac

# --- 1. 时区 → 候选范围 ---
# 只动 Arch 官方源，不碰 CachyOS 自己的 mirrorlist，免得改坏系统。
if [ -e "/etc/pacman.d/cachyos-mirrorlist" ]; then
    warn "$(t "检测到 CachyOS 镜像列表，只动 Arch 官方源" "CachyOS mirrorlist found; Arch mirrors only")"
fi

TZ_PATH=""
if [ -L /etc/localtime ]; then
    TZ_PATH="$(readlink -f /etc/localtime 2>/dev/null || true)"
fi

CN=0
case "$TZ_PATH" in
    *Shanghai*|*Chongqing*|*Urumqi*|*PRC*) CN=1 ;;
esac

if [ "$CN" -eq 1 ]; then
    log "$(t "时区" "Timezone"): $(basename "${TZ_PATH:-$(t "未知" "unknown")}")（$(t "国内镜像优先" "China mirrors first")）"
else
    log "$(t "时区" "Timezone"): $(basename "${TZ_PATH:-$(t "未知" "unknown")}")（$(t "按国家自动筛" "auto-pick by country")）"
fi

# --- 2. 确保 reflector 在 ---
if ! command -v reflector >/dev/null 2>&1; then
    log "$(t "没有 reflector，先装上" "reflector missing, installing it")"
    pac_install reflector || true
fi

if ! command -v reflector >/dev/null 2>&1; then
    warn "$(t "reflector 装不上，跳过，mirrorlist 保持原样" "reflector unavailable; skipping, mirrorlist untouched")"
    warn "$(t "修好后重跑本模块即可" "Re-run this module once fixed")"
    exit 0
fi
success "$(t "reflector 就绪：$(command -v reflector)" "reflector ready: $(command -v reflector)")"

# --- 3. 备份（改之前先留退路） ---
if [ ! -f "$MIRRORLIST" ]; then
    warn "$(t "$MIRRORLIST 不存在，没什么可优化的，跳过" "$MIRRORLIST not found, nothing to optimize")"
    exit 0
fi

if [ ! -f "$ORIG_BAK" ]; then
    as_root cp -a "$MIRRORLIST" "$ORIG_BAK"
    success "$(t "原始镜像源已备份 → $ORIG_BAK" "Original mirrorlist backed up → $ORIG_BAK")"
else
    log "$(t "原始备份已存在，不覆盖：$ORIG_BAK" "Original backup exists, kept: $ORIG_BAK")"
fi

as_root cp -a "$MIRRORLIST" "$PREV_BAK"
log "$(t "改动前这一版也备份了 → $PREV_BAK" "Previous version backed up → $PREV_BAK")"

# --- 4. 生成新列表：只写临时文件，校验通过了才替换 ---
TMP_NEW="$(mktemp /tmp/chenpi-mirrorlist.XXXXXX)"
trap 'rm -f "$TMP_NEW"' EXIT

GEN_OK=0
if [ "$CN" -eq 1 ]; then
    log "$(t "第一轮：只取国内镜像，按速度排序" "Round 1: China mirrors, sorted by rate")"
    if as_root reflector --protocol https --country China --age 12 --number 10 --sort rate --save "$TMP_NEW"; then
        GEN_OK=1
    else
        warn "$(t "国内这轮失败，换全球候选再试" "China round failed, trying global")"
    fi
else
    CC=""
    if command -v curl >/dev/null 2>&1; then
        CC="$(curl -s --max-time 3 https://ipinfo.io/country 2>/dev/null || true)"
    fi
    # 只留大写字母，避免把 HTML / 报错当成国家码
    CC="$(printf '%s' "$CC" | tr -cd 'A-Z' || true)"
    if [ "${#CC}" -eq 2 ]; then
        log "$(t "识别到的国家" "Detected country"): $CC（$(t "按它筛镜像" "filtered by it")）"
        log "$(t "第一轮：只取 $CC 镜像，按速度排序" "Round 1: $CC mirrors, sorted by rate")"
        if as_root reflector --protocol https --country "$CC" --age 12 --number 10 --sort rate --save "$TMP_NEW"; then
            GEN_OK=1
        else
            warn "$(t "按 $CC 筛选失败，换全球候选再试" "Filter by $CC failed, trying global")"
        fi
    else
        log "$(t "识别不出国家，直接走全球候选" "Country unknown, going global")"
    fi
fi

if [ "$GEN_OK" -eq 0 ]; then
    log "$(t "第二轮：全球最新 30 个里按速度挑 10 个" "Round 2: best 10 of newest 30 globally")"
    if as_root reflector --protocol https --latest 30 --number 10 --sort rate --save "$TMP_NEW"; then
        GEN_OK=1
    else
        warn "$(t "reflector 两轮都失败了" "reflector failed in both rounds")"
    fi
fi

if [ "$GEN_OK" -eq 0 ]; then
    warn "$(t "reflector 没生成可用列表，原 mirrorlist 一字节未动" "reflector produced nothing usable; original mirrorlist untouched")"
    warn "$(t "确认网络后重跑本模块即可" "Check the network, then re-run this module")"
    exit 0
fi

# --- 5. 校验生成结果（reflector 中途挂掉会留半截文件，不能直接信） ---
SERVER_COUNT="$(grep -c '^[[:space:]]*Server' "$TMP_NEW" 2>/dev/null || true)"
SERVER_COUNT="${SERVER_COUNT:-0}"
log "$(t "生成结果" "Generated"): $(t "$SERVER_COUNT 个 Server 行" "$SERVER_COUNT Server lines")"

if [ "$SERVER_COUNT" -lt 3 ]; then
    warn "$(t "只有 $SERVER_COUNT 个 Server 行，太可疑，不动原 mirrorlist" "Only $SERVER_COUNT Server lines; original mirrorlist untouched")"
    exit 0
fi

# 光排序不够：还是得真去探一下最前面几个镜像能不能下到 core.db（以前被超时和 404 坑过）
if command -v curl >/dev/null 2>&1; then
    PROBE_OK=0
    PROBE_N=0
    PROBE_LIST="$(grep -m3 '^[[:space:]]*Server' "$TMP_NEW" | awk '{print $3}' || true)"
    while read -r _url; do
        [ -z "$_url" ] && continue
        # 把 $repo / $arch 换成真实路径，拼出 core 库的 db 地址
        _url="${_url//\$repo\/os\/\$arch/core/os/x86_64}"
        if curl -fsIL --max-time 6 "${_url}/core.db" >/dev/null 2>&1; then
            PROBE_OK=1
            log "$(t "连通性探测通过：$_url" "Reachability probe OK: $_url")"
            break
        fi
        PROBE_N=$((PROBE_N + 1))
        [ "$PROBE_N" -ge 3 ] && break
    done <<< "$PROBE_LIST"

    if [ "$PROBE_OK" -eq 0 ]; then
        warn "$(t "前 3 个候选都连不上，不动原 mirrorlist" "Top 3 candidates unreachable; original mirrorlist untouched")"
        warn "$(t "多半是网络问题，恢复正常后重跑即可" "Likely a network issue; re-run when it recovers")"
        exit 0
    fi
else
    log "$(t "没有 curl，跳过连通性探测" "No curl; skipping reachability probe")"
fi

# --- 6. 替换（先落旁边再 mv，避免写一半断电留个空文件） ---
log "$(t "写入新的 mirrorlist" "Writing new mirrorlist")"
as_root install -m 0644 -o root -g root "$TMP_NEW" "${MIRRORLIST}.chenpi-new"
as_root mv "${MIRRORLIST}.chenpi-new" "$MIRRORLIST"

success "$(t "镜像源已更新：$SERVER_COUNT 个 https 镜像，按速度排序" "Mirrors updated: $SERVER_COUNT https mirrors by rate")"

log "$(t "排在最前面的几个：" "Top mirrors:")"
grep -m3 '^[[:space:]]*Server' "$MIRRORLIST" 2>/dev/null | sed 's/^[[:space:]]*/       /' || true

info_kv "$(t "生效文件" "Active file")" "$MIRRORLIST"
info_kv "$(t "原始备份" "Original backup")" "$ORIG_BAK" "$(t "永不覆盖" "never overwritten")"
info_kv "$(t "上一版备份" "Previous backup")" "$PREV_BAK" "$(t "回退：cp $PREV_BAK $MIRRORLIST" "Rollback: cp $PREV_BAK $MIRRORLIST")"
log "$(t "新源要靠 pacman 同步数据库才生效，01a-base.sh 接着做" "New mirrors need a pacman sync; 01a-base.sh does it next")"
success "$(t "镜像源优化完成" "Mirror optimization done")"
