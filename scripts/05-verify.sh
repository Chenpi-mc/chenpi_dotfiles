#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 05-verify.sh — 装后对账（固定最后一个跑）
# 改写自 ref/shorin-arch-setup/scripts/05-verify-desktop.sh（AGPL-3.0）
#
# 和参考版最大的区别：他那是“黑盒启发式”检查 —— 去猜自己的桌面变体应该有哪些
# 包（dms / quickshell 在不在），最后用 pacman -T 核对一张他自己拼的发货单。
# 我们的对账是主控登记制，不靠猜：
#   * install.sh 每次开跑先把 $VERIFY_LIST 清空
#   * 各模块装包时通过 pac_install / aur_install 自动 verify_add 登记“这次打算装的包”
#   * 本模块最后一次性核对，缺了就 exit 1（主控把它记为失败，修好重跑）
#
# 本模块做三件事，全程只读，一个包都不装：
#   1. 软件包对账：读 $VERIFY_LIST → 用 pacman -Qq 逐个核对
#   2. 关键配置文件是否到位（niri / fish / kitty / fcitx5 / starship）
#   3. 壁纸目录是否存在、里面有没有文件
# ==============================================================================

# TARGET_USER / TARGET_HOME 由主控 detect_target_user 设置并 export。
# 这里给个兜底，方便单独跑本模块调试（注意 HOME 不一定是目标用户家目录，
# 真正的判据始终是 TARGET_HOME）。
TARGET_HOME="${TARGET_HOME:-$HOME}"

# WALLPAPER_DIR 在 apps.conf 里定义。主控（install.sh）source 之后不会 export 给模块，
# 所以这里自己 source 一份。apps.conf 开头写明“别写会执行的东西”，source 是安全的。
if [ -f "$REPO_ROOT/apps.conf" ]; then
    source "$REPO_ROOT/apps.conf"
fi
WALLPAPER_DIR="${WALLPAPER_DIR:-chenpi_file/wallpaper}"

require_arch
section "装后对账" "软件包 + 关键配置 + 壁纸"

# FAILED=1 表示这次对账有缺失，模块最后 exit 1
FAILED=0
MISSING_PKGS=()
MISSING_PATHS=()

# ------------------------------- 1. 软件包对账 -------------------------------
hr
log "第一步：核对这次登记要装的软件包"
info_kv "对账清单" "$VERIFY_LIST"

if [ ! -f "$VERIFY_LIST" ]; then
    # 清单不存在不算失败：可能是所有装包模块都跳过了
    warn "对账清单不存在（$VERIFY_LIST），没有包需要核对"
else
    # 清单是一包一行，但同一个包可能被多个模块登记过 → 去重；
    # 顺手去掉行尾注释、首尾空白和空行，脏数据不至于把对账带偏
    mapfile -t CHECK_PKGS < <(tr -d '\r' < "$VERIFY_LIST" \
        | sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -v '^$' | sort -u)

    if [ ${#CHECK_PKGS[@]} -eq 0 ]; then
        warn "对账清单是空的 —— 前面的模块一个包都没登记"
    else
        log "共 ${#CHECK_PKGS[@]} 个包，逐个核对……"

        for p in "${CHECK_PKGS[@]}"; do
            # pacman -Qq <包名>：只在本地已安装数据库里精确找这个名字
            if pacman -Qq "$p" >/dev/null 2>&1; then
                continue
            fi
            # 再给一次机会：清单里偶尔会有“虚拟包 / 被别的包 provides 掉的包”，
            # 这种 pacman -Qq 查不到，但依赖其实已经满足。
            # pacman -T 输出为空 = 依赖能满足，就不当缺失处理，免得误报。
            if [ -z "$(pacman -T "$p" 2>/dev/null || true)" ]; then
                continue
            fi
            MISSING_PKGS+=("$p")
        done

        info_kv "登记" "${#CHECK_PKGS[@]} 个"
        info_kv "已装" "$(( ${#CHECK_PKGS[@]} - ${#MISSING_PKGS[@]} )) 个"

        if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
            success "软件包对账通过：${#CHECK_PKGS[@]} 个包全都在"
        else
            info_kv "缺失" "${#MISSING_PKGS[@]} 个"
            error "有 ${#MISSING_PKGS[@]} 个包没装上"
            for p in "${MISSING_PKGS[@]}"; do
                echo -e "       $CROSS ${H_YELLOW}${p}${NC}"
                write_log "MISSING-PKG" "$p"
            done
            log "常见原因：网络 / 镜像源不通、AUR 助手没装好、包之间有冲突、源没配全"
            log "手动补：sudo pacman -S --needed <包名> 或 yay -S --needed <包名>，然后重跑本模块"
            FAILED=1
        fi
    fi
fi

# ------------------------------- 2. 关键配置 -------------------------------
hr
log "第二步：核对关键配置文件（由 04 模块从 dotfiles 恢复）"
info_kv "目标用户" "${TARGET_USER:-未知}" "$TARGET_HOME"

# 只挑“没有它就没法用 / 一眼就知道坏了”的关键路径，不把 apps.conf 里几十项全查一遍
# （全查的话，任何一个可选配置没同步都会让对账失败，太吵）。
# 每条格式：相对 ~/.config 的路径|给人看的说明
CONFIG_CHECKS=(
    "niri/config.kdl|niri 主配置"
    "fish/config.fish|fish 配置"
    "kitty/kitty.conf|kitty 终端配置"
    "fcitx5/profile|fcitx5 输入法配置"
    "starship.toml|starship 提示符"
)

if [ ! -d "$TARGET_HOME/.config" ]; then
    echo -e "   $CROSS ${H_YELLOW}缺 ~/.config 整个目录：$TARGET_HOME/.config${NC}"
    MISSING_PATHS+=("$TARGET_HOME/.config")
    FAILED=1
else
    for item in "${CONFIG_CHECKS[@]}"; do
        rel="${item%%|*}"
        desc="${item##*|}"
        path="$TARGET_HOME/.config/$rel"
        # 用 -e 判断：文件、目录、指向有效目标的软链接都算在；
        # 断掉的软链接 -e 为假，正好当成“缺失 / 损坏”报出来
        if [ -e "$path" ]; then
            success "$desc 在：$path"
        else
            echo -e "   $CROSS ${H_YELLOW}缺 $desc：$path${NC}"
            write_log "MISSING-CONFIG" "$path"
            MISSING_PATHS+=("$path")
            FAILED=1
        fi
    done
fi

# ------------------------------- 3. 壁纸目录 -------------------------------
hr
log "第三步：核对壁纸目录"

# WALLPAPER_DIR 正常是相对家目录的路径，但也允许有人写成绝对路径，两种都认
case "$WALLPAPER_DIR" in
    /*) WALLPAPER_PATH="$WALLPAPER_DIR" ;;
    *)  WALLPAPER_PATH="$TARGET_HOME/$WALLPAPER_DIR" ;;
esac
info_kv "壁纸目录" "$WALLPAPER_PATH"

if [ ! -d "$WALLPAPER_PATH" ]; then
    echo -e "   $CROSS ${H_YELLOW}壁纸目录不存在：$WALLPAPER_PATH${NC}"
    write_log "MISSING-WALLPAPER" "$WALLPAPER_PATH"
    MISSING_PATHS+=("$WALLPAPER_PATH")
    FAILED=1
else
    # 目录在但里面空了，niri 起来照样没壁纸，一样算没通过
    WP_FILES="$(find "$WALLPAPER_PATH" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    if [ "$WP_FILES" -gt 0 ]; then
        success "壁纸目录在，里面 ${WP_FILES} 个文件"
    else
        warn "壁纸目录在，但里面是空的：$WALLPAPER_PATH"
        write_log "EMPTY-WALLPAPER" "$WALLPAPER_PATH"
        FAILED=1
    fi
fi

# ------------------------------- 汇总 -------------------------------
hr
section "对账结果" "本模块是最后一步，不装任何包"

if [ "$FAILED" -eq 0 ]; then
    success "对账全部通过：软件包、关键配置、壁纸都到位"
    # 刻意不删 $VERIFY_LIST：留着方便事后看这次到底打算装了什么。
    # 主控下次开跑会自己清空，不会污染下一次对账。
    log "这次的对账清单留在 $VERIFY_LIST，想看可以 cat 一下"
    exit 0
fi

error "对账没通过 —— 上面标 $CROSS 的就是缺的"
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    info_kv "缺的包" "${#MISSING_PKGS[@]} 个" "${MISSING_PKGS[*]}"
fi
if [ ${#MISSING_PATHS[@]} -gt 0 ]; then
    info_kv "缺的路径" "${#MISSING_PATHS[@]} 个"
    printf '       %s\n' "${MISSING_PATHS[@]}"
fi
log "修好后重跑：./install.sh（已完成的模块自动跳过）｜./install.sh --force（全部重来）"
exit 1
