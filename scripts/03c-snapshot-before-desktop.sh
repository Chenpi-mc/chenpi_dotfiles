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
# 位置：02b 装完必须的包之后、04-restore-config 往系统里铺桌面配置之前。
# 下一步是大范围覆盖用户配置，最容易翻车，所以先立一个还原点。
#
# 【刻意不做的事】参考版在这个模块里还会删掉用户家目录下的
#     ~/.config/systemd/user/hyprland-autostart.service
#     ~/.config/systemd/user/niri-autostart.service
# 我们绝不删：用户本来就在用 niri，那些 autostart 是他自己配置的一部分，
# 而 04-restore-config 的任务正是把他的 niri 配置恢复回来 —— 顺手删 autostart
# 等于搞坏刚装好的桌面，而且那件事跟「打还原点」本身没关系。
# ==============================================================================

require_arch

# 还原点描述（幂等标记）：标出归属，重复运行也靠它判断是否已经打过
SNAP_ROOT_DESC="chenpi-桌面改动前"
SNAP_HOME_DESC="chenpi-桌面改动前"

log "$(t "阶段 3c：桌面改动前的还原点" "Stage 3c: snapshot before desktop changes")"

# TARGET_USER / TARGET_HOME 由主控 detect_target_user export；单独手跑本模块时
# 它们是空的，这里自己检测一次（免得读到空变量报一堆怪错）
if [ -z "${TARGET_USER:-}" ]; then
    log "$(t "没读到 TARGET_USER（多半是单独跑了本模块），自己检测一次" "TARGET_USER unset (standalone run) — detecting it")"
    detect_target_user
fi
log "$(t "目标用户：$TARGET_USER（$TARGET_HOME）" "target user: $TARGET_USER ($TARGET_HOME)")"
log "$(t "配置仓库：$REPO_ROOT" "repo: $REPO_ROOT")"

if [ ! -d "${TARGET_HOME:-}" ]; then
    error "$(t "找不到 $TARGET_USER 的家目录（TARGET_HOME=${TARGET_HOME:-空}）" "no home directory for $TARGET_USER (TARGET_HOME=${TARGET_HOME:-empty})")"
    exit 1
fi

# ------------------------------------------------------------------------------
# 0. 能不能打快照？不能就说明原因并干净地退出
# ------------------------------------------------------------------------------
# 这里的「不适用」不算失败：根分区不是 btrfs、或者 00-btrfs-init 没跑成，
# 都属于环境问题，桌面配置该装的还是要装。
if ! command -v snapper >/dev/null 2>&1; then
    warn "$(t "没装 snapper，这次不打还原点（说明 00-btrfs-init 没跑成）" "no snapper — skipping the snapshot (00-btrfs-init did not run)")"
    warn "$(t "桌面配置照常继续，但这次没有退路" "desktop config continues, but with no rollback point")"
    exit 0
fi

ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
if [ "$ROOT_FSTYPE" != "btrfs" ]; then
    warn "$(t "根分区不是 Btrfs（${ROOT_FSTYPE:-未知}），没有快照可用，跳过" "root fs is ${ROOT_FSTYPE:-unknown}, not btrfs — no snapshots, skipping")"
    exit 0
fi

# ------------------------------------------------------------------------------
# 1. root 还原点（关键）
# ------------------------------------------------------------------------------
# 幂等判据：已经存在同名描述的还原点就跳过，重跑本模块不会多打快照。
ROOT_SNAP_OK=1

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    if as_root snapper -c root list --columns description 2>/dev/null | grep -Fqx "$SNAP_ROOT_DESC"; then
        success "$(t "root 上已经有「$SNAP_ROOT_DESC」这个还原点，跳过" "root already has \"$SNAP_ROOT_DESC\" — skipping")"
    else
        log "$(t "在 root 上打还原点：「$SNAP_ROOT_DESC」" "creating root snapshot \"$SNAP_ROOT_DESC\"")"
        # --type single 明确这是一个人工存档点（不是 pre/post 对里的某一半）
        if exe as_root snapper -c root create --type single --description "$SNAP_ROOT_DESC"; then
            success "$(t "root 还原点打好了" "root snapshot created")"
        else
            warn "$(t "root 还原点没打上" "root snapshot failed")"
            ROOT_SNAP_OK=0
        fi
    fi
else
    warn "$(t "没有 root 的 snapper 配置，跳过 root 还原点" "no root snapper config — skipping the root snapshot")"
    warn "$(t "（root 配置由 00-btrfs-init 创建；根分区不是 btrfs 时不会有）" "(created by 00-btrfs-init; absent on non-btrfs)")"
    ROOT_SNAP_OK=0
fi

# ------------------------------------------------------------------------------
# 2. home 还原点（尽力而为）
# ------------------------------------------------------------------------------
# home 快照正好覆盖马上要恢复的 dotfiles；失败不要紧（root 有还原点就能救系统），
# 所以只警告不中断。
if as_root snapper list-configs 2>/dev/null | grep -q '^home '; then
    if as_root snapper -c home list --columns description 2>/dev/null | grep -Fqx "$SNAP_HOME_DESC"; then
        success "$(t "home 上已经有「$SNAP_HOME_DESC」这个还原点，跳过" "home already has \"$SNAP_HOME_DESC\" — skipping")"
    else
        log "$(t "在 home 上打还原点：「$SNAP_HOME_DESC」" "creating home snapshot \"$SNAP_HOME_DESC\"")"
        if exe as_root snapper -c home create --type single --description "$SNAP_HOME_DESC"; then
            success "$(t "home 还原点打好了" "home snapshot created")"
        else
            warn "$(t "home 还原点没打上，不影响后面的步骤" "home snapshot failed — non-fatal")"
        fi
    fi
else
    log "$(t "没有 home 的 snapper 配置（/home 不是独立 btrfs 子卷时常这样），跳过" "no home snapper config (common when /home is not a btrfs subvolume) — skipping")"
fi

# ------------------------------------------------------------------------------
# 3. 明确保留用户的桌面自启动项（只读检查，不删）
# ------------------------------------------------------------------------------
# 用 as_user 读家目录：主控以 root 跑时（runuser 切回目标用户）不会因为家目录
# 权限或属主问题误判成「文件不存在」。
for _au in "hyprland-autostart.service" "niri-autostart.service"; do
    if as_user test -f "$TARGET_HOME/.config/systemd/user/$_au"; then
        log "$(t "保留你现有的 $_au" "keeping your $_au")"
    fi
done

# ------------------------------------------------------------------------------
# 4. 收尾
# ------------------------------------------------------------------------------
if [ "$ROOT_SNAP_OK" -eq 0 ]; then
    error "$(t "root 还原点没打上，接下来改桌面配置没有退路。先修好 snapper 再重跑本模块。" "no root snapshot — no rollback point for the desktop changes. Fix snapper and rerun.")"
    exit 1
fi

success "$(t "阶段 3c 完成：还原点就位" "Stage 3c done — the rollback point is in place")"
log "$(t "退回方法：sudo snapper -c root undochange <编号>..0" "roll back: sudo snapper -c root undochange <id>..0")"
