#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 03c-snapshot-before-desktop.sh — 动桌面配置之前打一个还原点
#
# 骨架改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/03c-snapshot-before-desktop.sh
# （AGPL-3.0）
#
# 它在整个流程里的位置：02b 装完必须的包之后、04-restore-config 往系统里塞
# 桌面 / dotfiles 配置之前。下一步是「大范围覆盖用户配置」，是最容易翻车的
# 一步，所以先立一个还原点。
#
# 【刻意不做的事】参考版在这个模块里还会删掉用户家目录下的
#     ~/.config/systemd/user/hyprland-autostart.service
#     ~/.config/systemd/user/niri-autostart.service
# 我们绝不删：
#   1. 用户正在用 niri，那些 autostart 是他自己配置的一部分；
#   2. 04-restore-config 的任务是把他的 niri 配置恢复回来，
#      顺手删 autostart 等于搞坏他刚装好的桌面；
#   3. 那一步跟「打还原点」这件事本身没关系，属于夹带私货。
# ==============================================================================

require_arch

# 还原点的描述文本（标记）。写清楚归属，方便以后在 snapper list 里一眼认出
# 「哪些快照是我们脚本打的」。重复运行时靠这个字符串判断是否已经打过。
SNAP_ROOT_DESC="chenpi-桌面改动前"
SNAP_HOME_DESC="chenpi-桌面改动前"

section "阶段 3c" "桌面改动前的还原点"

# TARGET_USER / TARGET_HOME 由主控 install.sh 里的 detect_target_user 设置并 export，
# 这里直接用。只有「单独手跑这个模块」时它们才是空的，那时自己检测一次
# （这样单独跑也能用，不会因为读到空变量就报一堆怪错）。
if [ -z "${TARGET_USER:-}" ]; then
    log "没有读到 TARGET_USER（多半是单独跑了本模块），自己检测一次目标用户"
    detect_target_user
fi
info_kv "目标用户" "$TARGET_USER" "$TARGET_HOME"
info_kv "配置仓库" "$REPO_ROOT"

if [ ! -d "${TARGET_HOME:-}" ]; then
    error "找不到 $TARGET_USER 的家目录（TARGET_HOME=${TARGET_HOME:-空}）"
    exit 1
fi

# ------------------------------------------------------------------------------
# 0. 能不能打快照？不能就说明原因并干净地退出
# ------------------------------------------------------------------------------
# 这里的「不适用」不算失败：根分区不是 btrfs、或者 00-btrfs-init 没跑成，
# 都属于环境问题，桌面配置该装的还是要装（install.sh 也会继续下一步）。
if ! command -v snapper >/dev/null 2>&1; then
    warn "没装 snapper，这次不打还原点（说明 00-btrfs-init 没跑成）"
    warn "桌面配置照常继续，但这次没有退路：出问题只能手动收拾"
    exit 0
fi

ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
if [ "$ROOT_FSTYPE" != "btrfs" ]; then
    warn "根分区不是 Btrfs（检测到 ${ROOT_FSTYPE:-未知}），没有快照可用，跳过"
    exit 0
fi

# ------------------------------------------------------------------------------
# 1. root 还原点（关键）
# ------------------------------------------------------------------------------
# 幂等判据：已经存在同名描述的还原点就跳过。重跑本模块不会多打快照。
ROOT_SNAP_OK=1

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    if as_root snapper -c root list --columns description 2>/dev/null | grep -Fqx "$SNAP_ROOT_DESC"; then
        success "root 上已经有「$SNAP_ROOT_DESC」这个还原点，跳过"
    else
        log "在 root 上打还原点：「$SNAP_ROOT_DESC」"
        log "为什么：接下来 04-restore-config 要往 /etc、家目录里铺桌面配置，铺坏了用"
        log "  sudo snapper -c root undochange <快照编号>..0     就能整块退回来"
        # --type single 明确这是一个人工存档点（不是 pre/post 对里的某一半）
        if exe as_root snapper -c root create --type single --description "$SNAP_ROOT_DESC"; then
            success "root 还原点打好了"
        else
            warn "root 还原点没打上"
            ROOT_SNAP_OK=0
        fi
    fi
else
    warn "没有 root 的 snapper 配置，跳过 root 还原点"
    warn "（root 配置由 00-btrfs-init 创建；根分区不是 btrfs 时不会有）"
    ROOT_SNAP_OK=0
fi

# ------------------------------------------------------------------------------
# 2. home 还原点（尽力而为）
# ------------------------------------------------------------------------------
# home 快照对应「用户的配置和数据」这一层，正好覆盖马上要恢复的 dotfiles。
# 失败不要紧（root 有还原点就能救系统），所以只警告不中断。
if as_root snapper list-configs 2>/dev/null | grep -q '^home '; then
    if as_root snapper -c home list --columns description 2>/dev/null | grep -Fqx "$SNAP_HOME_DESC"; then
        success "home 上已经有「$SNAP_HOME_DESC」这个还原点，跳过"
    else
        log "在 home 上打还原点：「$SNAP_HOME_DESC」"
        if exe as_root snapper -c home create --type single --description "$SNAP_HOME_DESC"; then
            success "home 还原点打好了"
        else
            warn "home 还原点没打上，不影响后面的步骤"
        fi
    fi
else
    log "没有 home 的 snapper 配置（/home 不是独立 btrfs 子卷时常这样），跳过"
fi

# ------------------------------------------------------------------------------
# 3. 明确保留用户的桌面自启动项
# ------------------------------------------------------------------------------
# 参考版会删 hyprland-autostart / niri-autostart 这两个 user service，
# 我们只提示、不删（原因见文件头的【刻意不做的事】）。
# 这里把两个文件的存在情况打出来，纯只读，方便出问题时对着日志排查。
# 用 as_user 去读家目录：主控以 root 跑时（runuser 切回目标用户）不会因为
# 家目录权限或属主问题误判成「文件不存在」。
for _au in "hyprland-autostart.service" "niri-autostart.service"; do
    if as_user test -f "$TARGET_HOME/.config/systemd/user/$_au"; then
        log "保留你现有的 $_au（我们不动用户的 autostart）"
    fi
done

# ------------------------------------------------------------------------------
# 4. 收尾
# ------------------------------------------------------------------------------
if [ "$ROOT_SNAP_OK" -eq 0 ]; then
    error "root 还原点没打上，接下来改桌面配置没有退路。先修好 snapper 再重跑本模块。"
    exit 1
fi

success "阶段 3c 完成：还原点就位，可以放心改桌面配置了"
log "退回方法：sudo snapper -c root undochange <快照编号>..0   （编号用 snapper -c root list 查）"
