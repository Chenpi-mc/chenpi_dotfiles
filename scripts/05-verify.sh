#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 05-verify.sh — 装后对账；改写自 ref/shorin-arch-setup（AGPL-3.0）
# 固定最后跑：必须等所有模块登记完。登记制不靠猜 —— install.sh 先清空
# $VERIFY_LIST，各模块装包时经 pac_install / aur_install 登记，这里一次性核对；
# 缺了就 exit 1（主控记为失败，修好重跑）。全程只读，一个包都不装。

# TARGET_HOME 由主控设置并 export，这里兜底方便单独调试（判据是 TARGET_HOME，不是 HOME）。
TARGET_HOME="${TARGET_HOME:-$HOME}"

# WALLPAPER_DIR 在 apps.conf 里，主控不会 export 给模块，所以自己 source 一份（安全）。
if [ -f "$REPO_ROOT/apps.conf" ]; then
    source "$REPO_ROOT/apps.conf"
fi
WALLPAPER_DIR="${WALLPAPER_DIR:-chenpi_file/wallpaper}"

require_arch
log "$(t "装后对账：软件包 + 关键配置 + 壁纸" "post-install check: packages + key configs + wallpapers")"

# FAILED=1 表示这次对账有缺失，模块最后 exit 1
FAILED=0
MISSING_PKGS=()
MISSING_PATHS=()

# ------------------------------- 1. 软件包对账 -------------------------------
hr
log "$(t "第一步：核对这次登记要装的软件包" "Step 1: check registered packages")"
log "$(t "对账清单：$VERIFY_LIST" "checklist: $VERIFY_LIST")"

if [ ! -f "$VERIFY_LIST" ]; then
    # 清单不存在不算失败：可能是所有装包模块都跳过了
    warn "$(t "对账清单不存在，没有包要核对" "no checklist, nothing to check")"
else
    # 一包一行但可能被多个模块重复登记 → 去重；顺手去掉行尾注释、空白和空行
    mapfile -t CHECK_PKGS < <(tr -d '\r' < "$VERIFY_LIST" \
        | sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -v '^$' | sort -u)

    if [ ${#CHECK_PKGS[@]} -eq 0 ]; then
        warn "$(t "对账清单是空的（前面的模块一个包都没登记）" "checklist is empty (nothing registered)")"
    else
        log "$(t "共 ${#CHECK_PKGS[@]} 个包，逐个核对……" "checking ${#CHECK_PKGS[@]} packages...")"

        for p in "${CHECK_PKGS[@]}"; do
            if pacman -Qq "$p" >/dev/null 2>&1; then
                continue
            fi
            # 虚拟包 / 被 provides 掉的包：-Qq 查不到但依赖已满足，-T 为空就不算缺失
            if [ -z "$(pacman -T "$p" 2>/dev/null || true)" ]; then
                continue
            fi
            MISSING_PKGS+=("$p")
        done

        info_kv "$(t "登记" "registered")" "$(t "${#CHECK_PKGS[@]} 个" "${#CHECK_PKGS[@]}")"
        info_kv "$(t "已装" "installed")" "$(t "$(( ${#CHECK_PKGS[@]} - ${#MISSING_PKGS[@]} )) 个" "$(( ${#CHECK_PKGS[@]} - ${#MISSING_PKGS[@]} ))")"

        if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
            success "$(t "软件包对账通过：${#CHECK_PKGS[@]} 个包全都在" "all ${#CHECK_PKGS[@]} packages present")"
        else
            info_kv "$(t "缺失" "missing")" "$(t "${#MISSING_PKGS[@]} 个" "${#MISSING_PKGS[@]}")"
            error "$(t "有 ${#MISSING_PKGS[@]} 个包没装上" "${#MISSING_PKGS[@]} packages missing")"
            for p in "${MISSING_PKGS[@]}"; do
                echo -e "       $CROSS ${H_YELLOW}${p}${NC}"
                write_log "MISSING-PKG" "$p"
            done
            log "$(t "常见原因：网络 / 源不通、AUR 助手没装好、包冲突" "usual causes: network/mirrors, no AUR helper, conflicts")"
            log "$(t "手动补：sudo pacman -S --needed <包名>，然后重跑本模块" "manual: sudo pacman -S --needed <pkg>, then rerun")"
            FAILED=1
        fi
    fi
fi

# ------------------------------- 2. 关键配置 -------------------------------
hr
log "$(t "第二步：核对关键配置文件（由 04 模块恢复）" "Step 2: check key configs (restored by module 04)")"
log "$(t "目标用户：${TARGET_USER:-未知}（$TARGET_HOME）" "target user: ${TARGET_USER:-unknown} ($TARGET_HOME)")"

# 只挑“没有它就没法用”的关键路径，不查 apps.conf 里几十项 —— 否则任何一个
# 可选配置没同步都会让对账失败，太吵。每条格式：相对 ~/.config 的路径|给人看的说明
CONFIG_CHECKS=(
    "niri/config.kdl|$(t "niri 主配置" "niri config")"
    "fish/config.fish|$(t "fish 配置" "fish config")"
    "kitty/kitty.conf|$(t "kitty 终端配置" "kitty config")"
    "fcitx5/profile|$(t "fcitx5 输入法配置" "fcitx5 config")"
    "starship.toml|$(t "starship 提示符" "starship prompt")"
)

if [ ! -d "$TARGET_HOME/.config" ]; then
    echo -e "   $CROSS ${H_YELLOW}$(t "缺 ~/.config 整个目录：$TARGET_HOME/.config" "missing ~/.config dir: $TARGET_HOME/.config")${NC}"
    MISSING_PATHS+=("$TARGET_HOME/.config")
    FAILED=1
else
    for item in "${CONFIG_CHECKS[@]}"; do
        rel="${item%%|*}"
        desc="${item##*|}"
        path="$TARGET_HOME/.config/$rel"
        # 用 -e：文件、目录、有效软链接都算在；断掉的软链接正好报成“缺失 / 损坏”
        if [ -e "$path" ]; then
            success "$(t "$desc 在：$path" "$desc found: $path")"
        else
            echo -e "   $CROSS ${H_YELLOW}$(t "缺 $desc：$path" "missing $desc: $path")${NC}"
            write_log "MISSING-CONFIG" "$path"
            MISSING_PATHS+=("$path")
            FAILED=1
        fi
    done
fi

# ------------------------------- 3. 壁纸目录 -------------------------------
hr
log "$(t "第三步：核对壁纸目录" "Step 3: check wallpaper dir")"

# WALLPAPER_DIR 一般是相对家目录的路径，但允许写成绝对路径，两种都认
case "$WALLPAPER_DIR" in
    /*) WALLPAPER_PATH="$WALLPAPER_DIR" ;;
    *)  WALLPAPER_PATH="$TARGET_HOME/$WALLPAPER_DIR" ;;
esac
log "$(t "壁纸目录：$WALLPAPER_PATH" "wallpaper dir: $WALLPAPER_PATH")"

if [ ! -d "$WALLPAPER_PATH" ]; then
    echo -e "   $CROSS ${H_YELLOW}$(t "壁纸目录不存在：$WALLPAPER_PATH" "wallpaper dir missing: $WALLPAPER_PATH")${NC}"
    write_log "MISSING-WALLPAPER" "$WALLPAPER_PATH"
    MISSING_PATHS+=("$WALLPAPER_PATH")
    FAILED=1
else
    # 目录在但里面空了，niri 起来照样没壁纸，一样算没通过。
    # find 出错时管道会返回非零，pipefail 下会把赋值和 set -e 一起带走 → || true 兜底
    WP_FILES="$(find "$WALLPAPER_PATH" -maxdepth 1 -type f 2>/dev/null | wc -l || true)"
    if [ "$WP_FILES" -gt 0 ]; then
        success "$(t "壁纸目录在，里面 ${WP_FILES} 个文件" "wallpaper dir ok, ${WP_FILES} files")"
    else
        warn "$(t "壁纸目录在，但里面是空的" "wallpaper dir is empty")"
        write_log "EMPTY-WALLPAPER" "$WALLPAPER_PATH"
        FAILED=1
    fi
fi

# ------------------------------- 汇总 -------------------------------
hr
log "$(t "对账结果：最后一步，不装任何包" "check result: runs last, installs nothing")"

if [ "$FAILED" -eq 0 ]; then
    success "$(t "对账全部通过：软件包、关键配置、壁纸都到位" "all checks passed: packages, configs, wallpapers")"
    # 刻意不删 $VERIFY_LIST：方便事后看这次打算装什么；主控下次开跑会自己清空
    log "$(t "清单留在 $VERIFY_LIST，想看可以 cat" "checklist kept at $VERIFY_LIST")"
    exit 0
fi

error "$(t "对账没通过 —— 上面标 $CROSS 的就是缺的" "check failed; items marked $CROSS are missing")"
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    info_kv "$(t "缺的包" "missing pkgs")" "$(t "${#MISSING_PKGS[@]} 个" "${#MISSING_PKGS[@]}")" "${MISSING_PKGS[*]}"
fi
if [ ${#MISSING_PATHS[@]} -gt 0 ]; then
    info_kv "$(t "缺的路径" "missing paths")" "$(t "${#MISSING_PATHS[@]} 个" "${#MISSING_PATHS[@]}")"
    printf '       %s\n' "${MISSING_PATHS[@]}"
fi
log "$(t "修好后重跑 ./install.sh（已完成的模块自动跳过）" "fix and rerun ./install.sh (skips done modules)")"
exit 1
