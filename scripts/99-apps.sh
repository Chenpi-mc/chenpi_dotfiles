#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 99-apps.sh — 按清单装应用；改写自 ref/shorin-arch-setup（AGPL-3.0）
# 只负责装包，配置归 04 模块。清单：dotfiles/pkglist.txt（官方源 + 社区源）
# 与 dotfiles/pkglist-aur.txt（AUR）。个别包装不上（sunloginclient 这类私有包）
# 不算模块失败：记下来写份报告，模块仍 exit 0 —— 真正把关的是 05-verify。
# 可选开关 APPS_AUR_FALLBACK=1：把“源里查不到”的包再丢给 AUR 试一次（默认关，
# 那批多半来自没配好的社区源，而且不少是 -git，现场编译很慢）。

REPO_LIST="$REPO_ROOT/dotfiles/pkglist.txt"
AUR_LIST="$REPO_ROOT/dotfiles/pkglist-aur.txt"
AUR_FALLBACK="${APPS_AUR_FALLBACK:-0}"

# TARGET_HOME 由主控设置并 export；兜底是为了单独调试本模块
TARGET_HOME="${TARGET_HOME:-$HOME}"

require_arch
section "$(t "按清单装应用" "Install apps from list")" "$(t "官方源清单 + AUR 清单" "repo + AUR lists")"

# ------------------------------- 1. 读清单 -------------------------------
hr

read_pkglist() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -v '^$' || true
}

if [ ! -f "$REPO_LIST" ]; then
    warn "$(t "找不到官方源清单：$REPO_LIST" "repo list not found: $REPO_LIST")"
fi
if [ ! -f "$AUR_LIST" ]; then
    warn "$(t "找不到 AUR 清单：$AUR_LIST" "AUR list not found: $AUR_LIST")"
fi
if [ ! -f "$REPO_LIST" ] && [ ! -f "$AUR_LIST" ]; then
    error "$(t "两份清单都不在（仓库 clone 完整吗？）" "both lists missing (incomplete clone?)")"
    exit 0
fi

mapfile -t WANT_REPO < <(read_pkglist "$REPO_LIST")
mapfile -t WANT_AUR < <(read_pkglist "$AUR_LIST")
info_kv "$(t "官方源清单" "repo list")" "$(t "${#WANT_REPO[@]} 个包" "${#WANT_REPO[@]} pkgs")" "dotfiles/pkglist.txt"
info_kv "$(t "AUR 清单" "AUR list")" "$(t "${#WANT_AUR[@]} 个包" "${#WANT_AUR[@]} pkgs")" "dotfiles/pkglist-aur.txt"

if [ ${#WANT_REPO[@]} -eq 0 ] && [ ${#WANT_AUR[@]} -eq 0 ]; then
    warn "$(t "清单是空的（或者整份都被注释掉了），跳过" "lists are empty or fully commented out, skipping")"
    exit 0
fi

# ------------------------------- 2. 分类 -------------------------------
hr
log "$(t "第一步：先分类，免得一颗坏包把整批带崩" "Step 1: classify first, so one bad pkg can't break the batch")"

# 判断元素在不在数组里（小工具，不动 00-utils）
in_array() {
    local needle="$1"; shift
    local x
    for x in "$@"; do
        [ "$x" = "$needle" ] && return 0
    done
    return 1
}

REPO_OK=()        # 源里能查到 → pac_install
REPO_NO_SOURCE=() # 源里查不到 → 多半来自没配好的社区源
AUR_ONLY=()       # 源里没有的 AUR 包 → aur_install
AUR_VIA_REPO=()   # AUR 清单里但源里已有（比如 fbterm）→ pac_install，省编译

for p in "${WANT_REPO[@]:-}"; do
    [ -n "$p" ] || continue
    # pacman -Si 查的是本机已配置的 sync 数据库（纯本地，不走网络）
    if pacman -Si "$p" >/dev/null 2>&1; then
        REPO_OK+=("$p")
    else
        REPO_NO_SOURCE+=("$p")
    fi
done

for p in "${WANT_AUR[@]:-}"; do
    [ -n "$p" ] || continue
    # 有些包写在 AUR 清单里但早进官方源了（fbterm 就是），走官方源更稳
    if pacman -Si "$p" >/dev/null 2>&1; then
        AUR_VIA_REPO+=("$p")
    else
        AUR_ONLY+=("$p")
    fi
done

info_kv "$(t "源里能装" "from repo")" "$(t "$(( ${#REPO_OK[@]} + ${#AUR_VIA_REPO[@]} )) 个" "$(( ${#REPO_OK[@]} + ${#AUR_VIA_REPO[@]} ))")"
info_kv "$(t "走 AUR" "via AUR")" "$(t "${#AUR_ONLY[@]} 个" "${#AUR_ONLY[@]}")"
info_kv "$(t "源里查不到" "not in repo")" "$(t "${#REPO_NO_SOURCE[@]} 个" "${#REPO_NO_SOURCE[@]}")"

# 源里查不到又不在 AUR 清单里的 → 这台机器上没处可装，只提示不报错
UNKNOWN_PKGS=()
for p in "${REPO_NO_SOURCE[@]:-}"; do
    [ -n "$p" ] || continue
    if in_array "$p" "${AUR_ONLY[@]:-}"; then
        continue
    fi
    UNKNOWN_PKGS+=("$p")
done

if [ ${#UNKNOWN_PKGS[@]} -gt 0 ]; then
    warn "$(t "这 ${#UNKNOWN_PKGS[@]} 个包源里查不到，这次不装：" "${#UNKNOWN_PKGS[@]} pkgs not in any repo, skipped:")"
    printf '       %s\n' "${UNKNOWN_PKGS[@]}"
    log "$(t "它们多半来自 archlinuxcn 这类社区源" "they likely come from community repos like archlinuxcn")"
    log "$(t "把源配好后重跑：./install.sh --force" "configure the repo and rerun: ./install.sh --force")"
    log "$(t "或者手动补：yay -S <包名>" "or install by hand: yay -S <pkg>")"
fi

# ------------------------------- 3. 装包 -------------------------------
hr
log "$(t "第二步：开装" "Step 2: install")"

# 官方源那批：pac_install 内部 --needed + 自动登记对账清单，整批失败会退化成逐个装
if [ ${#REPO_OK[@]} -gt 0 ] || [ ${#AUR_VIA_REPO[@]} -gt 0 ]; then
    log "$(t "官方源软件包：$(( ${#REPO_OK[@]} + ${#AUR_VIA_REPO[@]} )) 个（已装的自动跳过）" "repo packages: $(( ${#REPO_OK[@]} + ${#AUR_VIA_REPO[@]} )) (installed ones skipped)")"
    pac_install "${REPO_OK[@]:-}" "${AUR_VIA_REPO[@]:-}" || warn "$(t "官方源这批不顺利，明细见报告" "repo batch had trouble, see the report")"
else
    log "$(t "官方源清单里没有可装的包" "no installable repo packages")"
fi

# AUR 那批。aur_install 会自己找 AUR 助手（yay / paru），找不到就跳过
if [ ${#AUR_ONLY[@]} -gt 0 ]; then
    log "$(t "AUR 软件包：${#AUR_ONLY[@]} 个（部分要现场编译，慢一点正常）" "AUR packages: ${#AUR_ONLY[@]} (some compile, may be slow)")"
    aur_install "${AUR_ONLY[@]:-}" || warn "$(t "AUR 这批不顺利，明细见报告" "AUR batch had trouble, see the report")"
else
    log "$(t "没有需要走 AUR 的包" "nothing to install from AUR")"
fi

# 可选：把“源里查不到”的那批也丢给 AUR 试一次（默认关，见文件头）
if [ "$AUR_FALLBACK" -eq 1 ] && [ ${#UNKNOWN_PKGS[@]} -gt 0 ]; then
    log "$(t "APPS_AUR_FALLBACK=1：把 ${#UNKNOWN_PKGS[@]} 个包交给 AUR 再试" "APPS_AUR_FALLBACK=1: retrying ${#UNKNOWN_PKGS[@]} pkgs via AUR")"
    aur_install "${UNKNOWN_PKGS[@]}" || warn "$(t "AUR 兜底这批不顺利" "AUR fallback batch had trouble")"
fi

# ------------------------------- 4. 核对与汇总 -------------------------------
hr
section "$(t "结果核对" "Result check")" "$(t "逐个确认清单上的包在不在" "check every listed package")"

OK_PKGS=()    # 已经装上了
FAIL_PKGS=()  # 试过但没装上
SKIP_PKGS=()  # 这台机器上没处可装（源里查不到，也没去 AUR 试）

# 两份清单合并、去重后再逐个核对（同一个包可能两边都写了）
mapfile -t ALL_WANT < <(printf '%s\n' "${WANT_REPO[@]:-}" "${WANT_AUR[@]:-}" \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | sort -u)

for p in "${ALL_WANT[@]:-}"; do
    [ -n "$p" ] || continue
    if has_pkg "$p"; then
        OK_PKGS+=("$p")
        continue
    fi
    # 区分“没处可装”和“装失败”；开了 AUR 兜底的那批其实已经试过 → 算失败
    if [ "$AUR_FALLBACK" -ne 1 ] && in_array "$p" "${UNKNOWN_PKGS[@]:-}"; then
        SKIP_PKGS+=("$p")
    else
        FAIL_PKGS+=("$p")
    fi
done

info_kv "$(t "清单合计" "total")" "$(t "${#ALL_WANT[@]} 个（去重后）" "${#ALL_WANT[@]} (deduped)")"
info_kv "$(t "已就位" "installed")" "$(t "${#OK_PKGS[@]} 个" "${#OK_PKGS[@]}")"
info_kv "$(t "装失败" "failed")" "$(t "${#FAIL_PKGS[@]} 个" "${#FAIL_PKGS[@]}")"
info_kv "$(t "源里查不到" "not in repo")" "$(t "${#SKIP_PKGS[@]} 个" "${#SKIP_PKGS[@]}")"

# 写一份报告到 ~/Documents，事后照单补装（参考版也是这么干的）
if [ ${#FAIL_PKGS[@]} -gt 0 ] || [ ${#SKIP_PKGS[@]} -gt 0 ]; then
    REPORT_DIR="$TARGET_HOME/Documents"
    REPORT_FILE="$REPORT_DIR/未装上的软件.txt"
    TMP_REPORT="$(mktemp)"
    {
        echo "$(t "chenpi_dotfiles — 应用清单执行结果" "chenpi_dotfiles — app list result")"
        echo "$(t "时间" "Time"): $(date '+%Y-%m-%d %H:%M:%S')"
        echo "$(t "目标用户" "User"): ${TARGET_USER:-$(t "未知" "unknown")}"
        echo "$(t "清单合计" "Total"): ${#ALL_WANT[@]}   $(t "已就位" "Installed"): ${#OK_PKGS[@]}   $(t "装失败" "Failed"): ${#FAIL_PKGS[@]}   $(t "源里查不到" "Not in repo"): ${#SKIP_PKGS[@]}"
        echo ""
        if [ ${#FAIL_PKGS[@]} -gt 0 ]; then
            echo "$(t "【装失败】（试过了，没装上）" "[FAILED] tried, not installed")"
            printf '  %s\n' "${FAIL_PKGS[@]}"
            echo ""
        fi
        if [ ${#SKIP_PKGS[@]} -gt 0 ]; then
            echo "$(t "【源里查不到】（这次没试装）" "[NOT IN REPO] not attempted")"
            printf '  %s\n' "${SKIP_PKGS[@]}"
            echo ""
        fi
        echo "$(t "补装建议：" "How to fix:")"
        echo "$(t "1) 确认网络与镜像源正常，重跑 ./install.sh --force" "1) check network/mirrors, rerun ./install.sh --force")"
        echo "$(t "2) AUR 包：yay -S <包名>" "2) AUR packages: yay -S <pkg>")"
        echo "$(t "3) 社区源的包：把对应的源配好再重跑" "3) community repo pkgs: configure the repo, then rerun")"
        echo "$(t "4) 私有包（sunloginclient 之类）装不上正常，不需要就从清单删掉" "4) private pkgs (sunloginclient etc.) often fail; drop unused ones")"
    } > "$TMP_REPORT"

    # 报告要落到目标用户家目录，所以用 as_user；root 跑的话把属主改回去
    if as_user mkdir -p "$REPORT_DIR" && as_user cp "$TMP_REPORT" "$REPORT_FILE"; then
        fix_owner "$REPORT_FILE"
        log "$(t "报告已写到：$REPORT_FILE" "report written to $REPORT_FILE")"
    else
        warn "$(t "报告写不进去（$REPORT_FILE），看上面的输出即可" "cannot write $REPORT_FILE, see the output above")"
    fi
    rm -f "$TMP_REPORT"
fi

# ------------------------------- 收尾 -------------------------------
hr
section "$(t "完成" "Done")" "$(t "应用清单" "app list")"

if [ ${#FAIL_PKGS[@]} -eq 0 ] && [ ${#SKIP_PKGS[@]} -eq 0 ]; then
    success "$(t "清单上的包全部到位（${#OK_PKGS[@]} 个）" "all listed packages installed (${#OK_PKGS[@]})")"
else
    if [ ${#FAIL_PKGS[@]} -gt 0 ]; then
        warn "$(t "有 ${#FAIL_PKGS[@]} 个包装失败：${FAIL_PKGS[*]}" "${#FAIL_PKGS[@]} failed: ${FAIL_PKGS[*]}")"
    fi
    if [ ${#SKIP_PKGS[@]} -gt 0 ]; then
        warn "$(t "有 ${#SKIP_PKGS[@]} 个包源里查不到：${SKIP_PKGS[*]}" "${#SKIP_PKGS[@]} not in any repo: ${SKIP_PKGS[*]}")"
    fi
    # 刻意不让模块失败：个别包（尤其私有包）装不上是常态，不该拦住整个流程。
    # 真正把关的是最后跑的 05-verify.sh —— 缺了才记失败、要求重跑。
    log "$(t "本模块不算失败，接着往下走；最后 05-verify.sh 会再核对一遍" "not a failure; 05-verify.sh re-checks at the end")"
fi

exit 0
