#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 主控 install.sh 里 detect_target_user 已经 export 了这三个变量；
# 这里只是兜底，让本模块单独跑（bash scripts/01-mirrors.sh）时不会因为 set -u 炸掉。
export RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER="${TARGET_USER:-$(id -un)}"
export TARGET_HOME="${TARGET_HOME:-$HOME}"

# ==============================================================================
# 01-mirrors.sh — 优化 pacman 镜像源（reflector）
#
# 对应参考项目 install.sh 里 "Pre-Flight / Mirrorlist Optimization" 那一段
# （ref/shorin-arch-setup/install.sh 约 317-410 行），但按我们的原则重写：
#
#   1. 不强制 root：改系统的命令全部走 as_root
#   2. reflector 没装就先装（走 pac_install，会登记到对账清单）
#   3. 生成结果先写临时文件，校验通过才替换 —— reflector 失败 / 生成的源
#      不可用的时候，一个字节都不动原来的 mirrorlist
#   4. 备份两份：一份"装机时第一次"的原件（永不覆盖），一份"每次改动前"的上一版
#   5. 不写 shorin 的私有源，也不写死 USTC（以前超时）/ QLU（以前 404）
#
# 本来是可选模块（install.sh 的 OPTIONAL_MENU 里默认不勾），所以勾了它
# 就表示"要做"，非交互模式下直接开跑；想临时反悔就设环境变量：
#   CHENPI_MIRRORS=skip  bash scripts/01-mirrors.sh    # 什么都不做
#   CHENPI_MIRRORS=force bash scripts/01-mirrors.sh    # 不问，直接重排
# ==============================================================================

require_arch
section "镜像源优化" "用 reflector 按实测速度重排 /etc/pacman.d/mirrorlist"

MIRRORLIST="/etc/pacman.d/mirrorlist"
# 原始备份：只在第一次生成，之后绝不覆盖（以后想回到装机当天的状态就用它）
ORIG_BAK="/etc/pacman.d/mirrorlist.chenpi.orig"
# 上一版备份：每次真正改动前覆盖一遍，方便只回退一步
PREV_BAK="/etc/pacman.d/mirrorlist.chenpi.prev"
MODE="${CHENPI_MIRRORS:-auto}"

# ------------------------------------------------------------------------------
# 0. 先问一句（或按环境变量决定）
# ------------------------------------------------------------------------------
case "$MODE" in
    skip)
        log "CHENPI_MIRRORS=skip：跳过镜像源优化，什么都不动"
        exit 0
        ;;
    force)
        log "CHENPI_MIRRORS=force：不问，直接重排"
        ;;
    auto|*)
        if [ -t 0 ]; then
            # 这个模块是用户/主控主动勾选的，所以默认就是"做"，给一次反悔机会
            echo -ne "   ${H_CYAN}开始用 reflector 重排镜像源？（30 秒不回答按继续）[Y/n] ${NC}"
            read -t 30 -r _ans || true
            case "${_ans:-}" in
                [Nn]*) log "已取消，镜像源保持原样"; exit 0 ;;
            esac
        else
            log "非交互模式：按用户的选择继续（要跳过请设 CHENPI_MIRRORS=skip）"
        fi
        ;;
esac

# ------------------------------------------------------------------------------
# 1. 看一眼时区 / 位置，决定候选范围
# ------------------------------------------------------------------------------
# CachyOS 自己也带一套镜像列表（cachyos-mirrorlist 等），那是给它自己的仓库用的，
# 本模块只管 Arch 官方源的 mirrorlist，不去碰 CachyOS 的文件，免得把系统改坏。
if [ -e "/etc/pacman.d/cachyos-mirrorlist" ]; then
    warn "检测到 CachyOS 自带镜像列表，本模块只处理 Arch 官方源，不动 CachyOS 的那些文件"
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
    info_kv "时区" "$(basename "${TZ_PATH:-未知}")" "按国内镜像优先"
else
    info_kv "时区" "$(basename "${TZ_PATH:-未知}")" "按通用策略（自动识别国家）"
fi

# ------------------------------------------------------------------------------
# 2. 确保 reflector 在
# ------------------------------------------------------------------------------
if ! command -v reflector >/dev/null 2>&1; then
    log "没有 reflector，先装上"
    pac_install reflector || true
fi

if ! command -v reflector >/dev/null 2>&1; then
    warn "reflector 装不上（源里没有或网络不通），这一步跳过，mirrorlist 保持原样"
    warn "修好之后重跑：bash scripts/01-mirrors.sh，或 ./install.sh --force"
    exit 0
fi
success "reflector 就绪：$(command -v reflector)"

# ------------------------------------------------------------------------------
# 3. 备份原 mirrorlist（改之前必须先有退路）
# ------------------------------------------------------------------------------
if [ ! -f "$MIRRORLIST" ]; then
    warn "$MIRRORLIST 不存在（pacman-mirrorlist 没装？），没什么可优化的，跳过"
    exit 0
fi

if [ ! -f "$ORIG_BAK" ]; then
    as_root cp -a "$MIRRORLIST" "$ORIG_BAK"
    success "原始镜像源已备份 → $ORIG_BAK（以后不再覆盖）"
else
    log "原始备份已存在，保留不覆盖：$ORIG_BAK"
fi

as_root cp -a "$MIRRORLIST" "$PREV_BAK"
log "改动前的这一版也备份了 → $PREV_BAK"

# ------------------------------------------------------------------------------
# 4. 生成新列表：只写临时文件，校验通过了才敢替换
# ------------------------------------------------------------------------------
TMP_NEW="$(mktemp /tmp/chenpi-mirrorlist.XXXXXX)"
trap 'rm -f "$TMP_NEW"' EXIT

GEN_OK=0
if [ "$CN" -eq 1 ]; then
    log "第一轮：只取国内镜像（--country China），按下载速度排序"
    if as_root reflector --protocol https --country China --age 12 --number 10 --sort rate --save "$TMP_NEW"; then
        GEN_OK=1
    else
        warn "国内这一轮失败（可能被墙 / 镜像不健康），换全球候选再试"
    fi
else
    CC=""
    if command -v curl >/dev/null 2>&1; then
        CC="$(curl -s --max-time 3 https://ipinfo.io/country 2>/dev/null || true)"
    fi
    # 只保留大写字母，避免拿到 HTML/报错内容
    CC="$(printf '%s' "$CC" | tr -cd 'A-Z')"
    if [ "${#CC}" -eq 2 ]; then
        info_kv "自动识别国家" "$CC" "按它筛镜像"
        log "第一轮：--country $CC，按下载速度排序"
        if as_root reflector --protocol https --country "$CC" --age 12 --number 10 --sort rate --save "$TMP_NEW"; then
            GEN_OK=1
        else
            warn "按 $CC 筛选失败，换全球候选再试"
        fi
    else
        log "识别不出国家（没 curl 或接口不通），直接走全球候选"
    fi
fi

if [ "$GEN_OK" -eq 0 ]; then
    log "第二轮：全球最新的 30 个候选里按速度挑 10 个"
    if as_root reflector --protocol https --latest 30 --number 10 --sort rate --save "$TMP_NEW"; then
        GEN_OK=1
    else
        warn "reflector 两轮都失败了"
    fi
fi

if [ "$GEN_OK" -eq 0 ]; then
    warn "reflector 没能生成可用的列表，原 mirrorlist 一个字节都没改"
    warn "想重试：先确认网络，再跑 bash scripts/01-mirrors.sh（或 ./install.sh --force）"
    exit 0
fi

# ------------------------------------------------------------------------------
# 5. 校验生成结果（reflector 中途挂掉会留半截文件，不能直接信）
# ------------------------------------------------------------------------------
SERVER_COUNT="$(grep -c '^[[:space:]]*Server' "$TMP_NEW" 2>/dev/null || true)"
SERVER_COUNT="${SERVER_COUNT:-0}"
info_kv "生成结果" "$SERVER_COUNT 个 Server 行"

if [ "$SERVER_COUNT" -lt 3 ]; then
    warn "生成结果不靠谱（只有 $SERVER_COUNT 个 Server 行），保守起见不动原 mirrorlist"
    exit 0
fi

# 再实际探一下排在最前面那几个镜像到底通不通：
# 以前被 USTC 超时、QLU 404 坑过，光"排序"不够，得确认能下到 core.db。
if command -v curl >/dev/null 2>&1; then
    PROBE_OK=0
    PROBE_N=0
    PROBE_LIST="$(grep -m3 '^[[:space:]]*Server' "$TMP_NEW" | awk '{print $3}')"
    while read -r _url; do
        [ -z "$_url" ] && continue
        # 把 $repo / $arch 换成真实路径，拼出 core 仓库的数据库地址
        _url="${_url//\$repo\/os\/\$arch/core/os/x86_64}"
        if curl -fsIL --max-time 6 "${_url}/core.db" >/dev/null 2>&1; then
            PROBE_OK=1
            log "连通性探测通过：$_url"
            break
        fi
        PROBE_N=$((PROBE_N + 1))
        [ "$PROBE_N" -ge 3 ] && break
    done <<< "$PROBE_LIST"

    if [ "$PROBE_OK" -eq 0 ]; then
        warn "前 3 个候选镜像都连不上（core.db 拉不到），不动原 mirrorlist"
        warn "多半是当前网络的问题，网络正常后重跑本模块即可"
        exit 0
    fi
else
    log "没有 curl，跳过连通性探测（reflector 已经按实测速度排过序）"
fi

# ------------------------------------------------------------------------------
# 6. 替换（先在旁边落好再 mv，避免写一半断电留个空文件）
# ------------------------------------------------------------------------------
log "写入新的 mirrorlist"
as_root install -m 0644 -o root -g root "$TMP_NEW" "${MIRRORLIST}.chenpi-new"
as_root mv "${MIRRORLIST}.chenpi-new" "$MIRRORLIST"

success "镜像源已更新：$SERVER_COUNT 个 https 镜像，按实测速度排序"

log "排在最前面的几个："
grep -m3 '^[[:space:]]*Server' "$MIRRORLIST" 2>/dev/null | sed 's/^[[:space:]]*/       /' || true

info_kv "生效文件" "$MIRRORLIST"
info_kv "原始备份" "$ORIG_BAK" "永不覆盖"
info_kv "上一版备份" "$PREV_BAK" "回退：cp $PREV_BAK $MIRRORLIST"
log "新源要等 pacman 重新同步数据库才完全生效，紧接着的 01a-base.sh 会做这件事"
success "镜像源优化完成"
