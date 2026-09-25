#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 99-apps.sh — 按清单装应用
# 改写自 ref/shorin-arch-setup/scripts/99-apps.sh（AGPL-3.0）
#
# 和参考版的区别：
#   * 参考版读他的 common-applist.txt / kde-applist.txt，还是 fzf 勾选式；
#     装完还顺手搞 flatpak、配 wine、配 virt-manager、克隆 LazyVim 覆盖 nvim 配置、
#     偷拷 firefox 配置 —— 这些我们一样都不做（配置归 04 模块，本模块只负责装）。
#   * 我们的清单就是这台机器的完整软件清单：
#       dotfiles/pkglist.txt      官方源（以及 archlinuxcn 这类已配好的社区源）
#       dotfiles/pkglist-aur.txt  AUR
#   * 个别包装不上（sunloginclient、wechat-appimage 这种私有 / 冷门包）不算模块失败：
#     记下来、写份报告，模块本身仍然 exit 0（真正把关的是最后跑的 05-verify）。
#
# 装包全部通过 pac_install / aur_install 做，好处有两个：
#   1. 内部用 --needed，所以“清单里的包已经装了”这种情况天然被容忍
#   2. 会自动把“打算装的包”登记进 $VERIFY_LIST，留给 05-verify 对账
#
# 可选开关：
#   APPS_AUR_FALLBACK=1 ./install.sh
#     —— 把“已配置的源里查不到”的包再丢给 AUR 试一次。默认关：
#        那些包多半来自没配好的 archlinuxcn 源，AUR 上未必有；而且不少是 -git
#        （要现场编译，dxvk-mingw-git、waifu2x-ncnn-vulkan 这种能编很久）。
# ==============================================================================

REPO_LIST="$REPO_ROOT/dotfiles/pkglist.txt"
AUR_LIST="$REPO_ROOT/dotfiles/pkglist-aur.txt"
AUR_FALLBACK="${APPS_AUR_FALLBACK:-0}"

# TARGET_USER / TARGET_HOME 由主控设置并 export；兜底是为了单独调试本模块
TARGET_HOME="${TARGET_HOME:-$HOME}"

require_arch
section "按清单装应用" "官方源清单 + AUR 清单"

# ------------------------------- 1. 读清单 -------------------------------
hr

# 读清单：去掉注释（含行尾注释）、首尾空白、空行，一个包名一行输出
read_pkglist() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -v '^$' || true
}

if [ ! -f "$REPO_LIST" ]; then
    warn "找不到官方源清单：$REPO_LIST"
fi
if [ ! -f "$AUR_LIST" ]; then
    warn "找不到 AUR 清单：$AUR_LIST"
fi
if [ ! -f "$REPO_LIST" ] && [ ! -f "$AUR_LIST" ]; then
    error "两份清单都不在（仓库 clone 完整吗？），没什么可装的"
    exit 0
fi

mapfile -t WANT_REPO < <(read_pkglist "$REPO_LIST")
mapfile -t WANT_AUR < <(read_pkglist "$AUR_LIST")
info_kv "官方源清单" "${#WANT_REPO[@]} 个包" "dotfiles/pkglist.txt"
info_kv "AUR 清单" "${#WANT_AUR[@]} 个包" "dotfiles/pkglist-aur.txt"

if [ ${#WANT_REPO[@]} -eq 0 ] && [ ${#WANT_AUR[@]} -eq 0 ]; then
    warn "清单是空的（或者整份都被注释掉了），跳过"
    exit 0
fi

# ------------------------------- 2. 分类 -------------------------------
hr
log "第一步：先把清单分个类，免得一颗坏包把整批 transaction 带崩"

# 判断元素在不在数组里（自己写的小工具，不动 00-utils 里的东西）
in_array() {
    local needle="$1"; shift
    local x
    for x in "$@"; do
        [ "$x" = "$needle" ] && return 0
    done
    return 1
}

REPO_OK=()        # 官方源清单里、已配置的源能查到的 → 走 pac_install
REPO_NO_SOURCE=() # 官方源清单里、源里查不到的 → 多半来自没配的社区源
AUR_ONLY=()       # AUR 清单里、源里也真没有的 → 走 aur_install
AUR_VIA_REPO=()   # AUR 清单里其实官方源就有的（比如 fbterm）→ 走 pac_install，省得编译

for p in "${WANT_REPO[@]:-}"; do
    [ -n "$p" ] || continue
    # pacman -Si 查的是本机已配置的 sync 数据库（纯本地操作，不走网络）
    if pacman -Si "$p" >/dev/null 2>&1; then
        REPO_OK+=("$p")
    else
        REPO_NO_SOURCE+=("$p")
    fi
done

for p in "${WANT_AUR[@]:-}"; do
    [ -n "$p" ] || continue
    # 有些包写在 AUR 清单里但早进官方源了（fbterm 就是），这种走官方源更稳
    if pacman -Si "$p" >/dev/null 2>&1; then
        AUR_VIA_REPO+=("$p")
    else
        AUR_ONLY+=("$p")
    fi
done

info_kv "源里能装" "$(( ${#REPO_OK[@]} + ${#AUR_VIA_REPO[@]} )) 个"
info_kv "走 AUR" "${#AUR_ONLY[@]} 个"
info_kv "源里查不到" "${#REPO_NO_SOURCE[@]} 个"

# 源里查不到的包：如果它正好也在 AUR 清单里，那不算异常（下面 AUR 那步会装它）；
# 否则就是这台机器上真的没处可装，单独提示（只提示，不报错）
UNKNOWN_PKGS=()
for p in "${REPO_NO_SOURCE[@]:-}"; do
    [ -n "$p" ] || continue
    if in_array "$p" "${AUR_ONLY[@]:-}"; then
        continue
    fi
    UNKNOWN_PKGS+=("$p")
done

if [ ${#UNKNOWN_PKGS[@]} -gt 0 ]; then
    warn "这 ${#UNKNOWN_PKGS[@]} 个包在已配置的源里查不到，这次不会装："
    printf '       %s\n' "${UNKNOWN_PKGS[@]}"
    log "它们多半来自 archlinuxcn 这类社区源，或者其实在 AUR："
    log "  * 把对应的源配好（或者把 archlinuxcn 加上）再重跑 ./install.sh --force"
    log "  * 也可以手动 yay -S <包名> 单独补"
fi

# ------------------------------- 3. 装包 -------------------------------
hr
log "第二步：开装"

# 官方源那批。pac_install 内部 --needed（已装的自动跳过）+ 自动登记对账清单，
# 整批失败时会自己退化成逐个装，所以不用我们操心冲突包
if [ ${#REPO_OK[@]} -gt 0 ] || [ ${#AUR_VIA_REPO[@]} -gt 0 ]; then
    log "官方源软件包：$(( ${#REPO_OK[@]} + ${#AUR_VIA_REPO[@]} )) 个（已装的会自动跳过，别慌）"
    pac_install "${REPO_OK[@]:-}" "${AUR_VIA_REPO[@]:-}" || warn "官方源这批不顺利，明细看下面报告"
else
    log "官方源清单里没有可装的包"
fi

# AUR 那批。aur_install 会自己找 AUR 助手（yay / paru），找不到就跳过并说明
if [ ${#AUR_ONLY[@]} -gt 0 ]; then
    log "AUR 软件包：${#AUR_ONLY[@]} 个（有 -bin 也有要编译的，慢一点属正常）"
    aur_install "${AUR_ONLY[@]:-}" || warn "AUR 这批不顺利，明细看下面报告"
else
    log "AUR 清单里没有需要走 AUR 的包"
fi

# 可选：把“源里查不到”的那批也丢给 AUR 助手试一次（默认关，见文件头说明）
if [ "$AUR_FALLBACK" -eq 1 ] && [ ${#UNKNOWN_PKGS[@]} -gt 0 ]; then
    log "APPS_AUR_FALLBACK=1：把源里查不到的 ${#UNKNOWN_PKGS[@]} 个包交给 AUR 再试一次"
    aur_install "${UNKNOWN_PKGS[@]}" || warn "AUR 兜底这批不顺利"
fi

# ------------------------------- 4. 核对与汇总 -------------------------------
hr
section "结果核对" "逐个确认清单上的包到底在不在"

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
    # 没装上：区分“这台机器上没处装”和“装失败了”。
    # 开了 AUR 兜底的话，那批其实已经试过了 → 归到失败里，更该让人看见
    if [ "$AUR_FALLBACK" -ne 1 ] && in_array "$p" "${UNKNOWN_PKGS[@]:-}"; then
        SKIP_PKGS+=("$p")
    else
        FAIL_PKGS+=("$p")
    fi
done

info_kv "清单合计" "${#ALL_WANT[@]} 个（去重后）"
info_kv "已就位" "${#OK_PKGS[@]} 个"
info_kv "装失败" "${#FAIL_PKGS[@]} 个"
info_kv "源里查不到" "${#SKIP_PKGS[@]} 个"

# 写一份报告到 ~/Documents，事后照单补装（参考版也是这么干的）
if [ ${#FAIL_PKGS[@]} -gt 0 ] || [ ${#SKIP_PKGS[@]} -gt 0 ]; then
    REPORT_DIR="$TARGET_HOME/Documents"
    REPORT_FILE="$REPORT_DIR/未装上的软件.txt"
    TMP_REPORT="$(mktemp)"
    {
        echo "chenpi_dotfiles — 应用清单执行结果"
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "目标用户: ${TARGET_USER:-未知}"
        echo "清单合计: ${#ALL_WANT[@]}   已就位: ${#OK_PKGS[@]}   装失败: ${#FAIL_PKGS[@]}   源里查不到: ${#SKIP_PKGS[@]}"
        echo ""
        if [ ${#FAIL_PKGS[@]} -gt 0 ]; then
            echo "【装失败】（试过了，没装上）"
            printf '  %s\n' "${FAIL_PKGS[@]}"
            echo ""
        fi
        if [ ${#SKIP_PKGS[@]} -gt 0 ]; then
            echo "【源里查不到】（这次没试装）"
            printf '  %s\n' "${SKIP_PKGS[@]}"
            echo ""
        fi
        echo "补装建议："
        echo "  1) 先确认网络与镜像源正常，然后重跑 ./install.sh --force"
        echo "  2) AUR 包：yay -S <包名>"
        echo "  3) 来自 archlinuxcn 这类社区的包：把对应的源配上再重跑"
        echo "  4) 个别私有包（sunloginclient / wechat-appimage 之流）装不上很正常，"
        echo "     确认自己不需要就直接从清单里删掉，免得每次对账都报缺失"
    } > "$TMP_REPORT"

    # 报告要落到目标用户家目录，所以用 as_user；root 跑的话把属主改回去
    if as_user mkdir -p "$REPORT_DIR" && as_user cp "$TMP_REPORT" "$REPORT_FILE"; then
        fix_owner "$REPORT_FILE"
        log "报告已写到：$REPORT_FILE"
    else
        warn "报告写不进去（$REPORT_FILE），结果看上面的输出就行"
    fi
    rm -f "$TMP_REPORT"
fi

# ------------------------------- 收尾 -------------------------------
hr
section "完成" "应用清单"

if [ ${#FAIL_PKGS[@]} -eq 0 ] && [ ${#SKIP_PKGS[@]} -eq 0 ]; then
    success "清单上的包全部到位（${#OK_PKGS[@]} 个）"
else
    if [ ${#FAIL_PKGS[@]} -gt 0 ]; then
        warn "有 ${#FAIL_PKGS[@]} 个包装失败：${FAIL_PKGS[*]}"
    fi
    if [ ${#SKIP_PKGS[@]} -gt 0 ]; then
        warn "有 ${#SKIP_PKGS[@]} 个包在已配置的源里查不到：${SKIP_PKGS[*]}"
    fi
    # 刻意不让模块失败：个别包（尤其私有包）装不上是常态，不该拦住整个安装流程。
    # 真正把关的是最后跑的 05-verify.sh —— 它核对登记过的包，缺了才记失败、要求重跑。
    log "本模块不算失败，接着往下走；最后 05-verify.sh 会再核对一遍"
fi

exit 0
