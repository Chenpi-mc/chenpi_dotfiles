#!/bin/bash
# 04-restore-config.sh — 把仓库里的配置铺回这台机器
# 顺序刻意是「先整体备份 → 再逐项覆盖」，出事能退回。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

SRC="$REPO_ROOT/dotfiles"
APPS_CONF="$REPO_ROOT/apps.conf"

# 单独跑本模块时的兜底（主控跑时这些变量已经 export 好了）
TARGET_USER="${TARGET_USER:-$(id -un)}"
TARGET_HOME="${TARGET_HOME:-$HOME}"
RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER TARGET_HOME RUN_AS_ROOT

if [ ! -f "$APPS_CONF" ]; then
    error "$(t "找不到 apps.conf（配置清单）" "apps.conf not found")"
    exit 1
fi
# shellcheck source=/dev/null
source "$APPS_CONF"

if [ ! -d "$SRC" ]; then
    error "$(t "找不到 $SRC —— 仓库里没有 dotfiles 目录" "no dotfiles dir in repo: $SRC")"
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_HOME=""
BACKUP_ETC=""

# ---- 1. 备份现有配置 ----
log "$(t "备份现有配置（覆盖前先备份）" "back up current config (backup first)")"

backup_items=()
for i in .config .vim .icons .themes "$WALLPAPER_DIR" \
         .bashrc .bash_profile .bash_logout .fbtermrc \
         .vimrc .gtkrc-2.0 .gitconfig .wget-hsts; do
    if [ -e "$TARGET_HOME/$i" ]; then backup_items+=("$i"); fi
done

if [ ${#backup_items[@]} -eq 0 ]; then
    warn "$(t "没有可备份的配置，跳过" "nothing to back up, skipping")"
else
    # 体积大又能重建的东西不进备份（聊天记录、浏览器缓存之类）
    tar_ex=()
    for i in "${BACKUP_EXCLUDES[@]}"; do tar_ex+=("--exclude=$i"); done

    BACKUP_HOME="$TARGET_HOME/dotfiles-backup-$STAMP.tar.gz"
    log "$(t "打包 ${#backup_items[@]} 项到 $BACKUP_HOME" "packing ${#backup_items[@]} items to $BACKUP_HOME")"
    as_root tar -czf "$BACKUP_HOME" -C "$TARGET_HOME" "${tar_ex[@]}" "${backup_items[@]}"
    fix_owner "$BACKUP_HOME"
    success "$(t "家目录备份完成" "home backup done") ($(du -h "$BACKUP_HOME" 2>/dev/null | cut -f1 || true))"
fi

# /etc 里会被覆盖的文件，单独打一份
etc_backup_items=()
for i in "${ETC_FILES[@]}"; do
    if [ -f "$i" ]; then etc_backup_items+=("${i#/etc/}"); fi
done
if [ ${#etc_backup_items[@]} -gt 0 ]; then
    BACKUP_ETC="$TARGET_HOME/dotfiles-backup-$STAMP-etc.tar.gz"
    as_root tar -czf "$BACKUP_ETC" -C /etc "${etc_backup_items[@]}"
    fix_owner "$BACKUP_ETC"
    success "$(t "系统配置备份完成（${#etc_backup_items[@]} 个文件）" "system config backed up (${#etc_backup_items[@]} files)")"
fi

# ---- 2. 恢复 .config ----
log "$(t "恢复 .config（清单里 ${#CONFIG_APPS[@]} 项）" "restore .config (${#CONFIG_APPS[@]} items listed)")"

as_user mkdir -p "$TARGET_HOME/.config"

restored=0
missing=()
for app in "${CONFIG_APPS[@]}"; do
    if [ -e "$SRC/.config/$app" ]; then
        # 先删掉目标里的同名项再拷，避免新旧文件混在一起
        as_user rm -rf "${TARGET_HOME:?}/.config/$app"
        as_user cp -r "$SRC/.config/$app" "$TARGET_HOME/.config/"
        restored=$((restored + 1))
    else
        missing+=("$app")
    fi
done

success "$(t ".config 恢复 $restored 项" ".config restored: $restored")"
if [ ${#missing[@]} -gt 0 ]; then
    warn "$(t "仓库里没有这 ${#missing[@]} 项，跳过：${missing[*]}" "not in repo, skipped (${#missing[@]}): ${missing[*]}")"
fi

# ---- 3. 恢复顶层 dotfile 和目录 ----
log "$(t "恢复顶层配置（dotfile 和目录）" "restore top-level dotfiles and dirs")"

file_n=0
for f in "${TOP_FILES[@]}"; do
    if [ -f "$SRC/$f" ]; then
        as_user rm -f "${TARGET_HOME:?}/$f"
        as_user cp -a "$SRC/$f" "$TARGET_HOME/"
        file_n=$((file_n + 1))
    fi
done
success "$(t "顶层 dotfile 恢复 $file_n 个" "top-level dotfiles restored: $file_n")"

dir_n=0
for d in "${TOP_DIRS[@]}"; do
    if [ -d "$SRC/$d" ]; then
        as_user rm -rf "${TARGET_HOME:?}/$d"
        as_user mkdir -p "$TARGET_HOME/$d"
        as_user cp -a "$SRC/$d/." "$TARGET_HOME/$d/"

        # .miyu 里含密钥和聊天记录，按清单排除掉（公开仓库里本来也没有）
        if [ "$d" = ".miyu" ]; then
            for ex in "${MIYU_EXCLUDES[@]}"; do
                as_user rm -rf "${TARGET_HOME:?}/$d/$ex"
            done
            log "$(t ".miyu 已恢复，排除了敏感项：${MIYU_EXCLUDES[*]}" ".miyu restored, excluded: ${MIYU_EXCLUDES[*]}")"
            warn "$(t ".miyu 的 config（API 密钥之类）不在仓库里，新机器要自己配" ".miyu config (API keys) is not in the repo, set it up yourself")"
        fi
        dir_n=$((dir_n + 1))
    fi
done
success "$(t "顶层目录恢复 $dir_n 个" "top-level dirs restored: $dir_n")"

# ---- 4. 恢复壁纸 ----
log "$(t "恢复壁纸：$WALLPAPER_DIR" "restore wallpapers: $WALLPAPER_DIR")"

if [ -d "$SRC/$WALLPAPER_DIR" ]; then
    as_user mkdir -p "$TARGET_HOME/$(dirname "$WALLPAPER_DIR")"
    as_user rm -rf "${TARGET_HOME:?}/$WALLPAPER_DIR"
    as_user cp -a "$SRC/$WALLPAPER_DIR" "$TARGET_HOME/$(dirname "$WALLPAPER_DIR")/"
    success "$(t "壁纸恢复" "wallpapers restored") ($(find "$TARGET_HOME/$WALLPAPER_DIR" -type f 2>/dev/null | wc -l || true) $(t "个文件" "files"))"
else
    warn "$(t "仓库里没有壁纸目录，跳过" "no wallpaper dir in repo, skipping")"
fi

# ---- 5. 恢复 /etc 下的系统配置（sddm 之类） ----
log "$(t "恢复系统级配置（/etc 下的文件）" "restore system config (files under /etc)")"

etc_n=0
for i in "${ETC_FILES[@]}"; do
    rel="${i#/etc/}"
    if [ -f "$REPO_ROOT/etc/$rel" ]; then
        as_root mkdir -p "$(dirname "$i")"
        as_root cp -a "$REPO_ROOT/etc/$rel" "$i"
        etc_n=$((etc_n + 1))
    fi
done
success "$(t "系统级配置恢复 $etc_n 个文件" "system config restored: $etc_n files")"

# ---- 6. root 跑的话把属主改回目标用户 ----
if [ "$RUN_AS_ROOT" -eq 1 ]; then
    log "$(t "修正文件属主（以 root 运行，属主要改回去）" "fix file ownership (running as root, fix the owner)")"
    fix_owner "$TARGET_HOME/.config" "$TARGET_HOME/$WALLPAPER_DIR"
    for i in "${TOP_FILES[@]}" "${TOP_DIRS[@]}"; do
        fix_owner "$TARGET_HOME/$i"
    done
    success "$(t "属主已改回 $TARGET_USER" "ownership back to $TARGET_USER")"
fi

# ---- 7. 显示管理器检查 ----
log "$(t "显示管理器检查（多个 DM 会互抢显示权限）" "display manager check (multiple DMs conflict)")"

check_dm_conflict
if [ -n "${DM_ENABLED:-}" ]; then
    success "$(t "已启用的：$DM_ENABLED" "enabled: $DM_ENABLED")"
elif [ -n "${DM_FOUND:-}" ]; then
    warn "$(t "装了显示管理器但都没启用，登录界面可能起不来" "DM installed but none enabled, login may not start")"
    warn "$(t "启用某个：sudo systemctl enable <名字>" "enable one: sudo systemctl enable <name>")"
else
    warn "$(t "没有显示管理器 —— niri 从 TTY 起，或另装一个" "no DM; start niri from a TTY or install one")"
fi

# ---- 汇总 ----
log "$(t "配置恢复完成" "restore complete")"

info_kv "$(t "配置目录" "config dir")" "$TARGET_HOME/.config" "$(ls "$TARGET_HOME/.config" 2>/dev/null | wc -l || true) $(t "项" "entries")"
info_kv "$(t "壁纸目录" "wallpaper dir")" "$TARGET_HOME/$WALLPAPER_DIR" ""
if [ -n "$BACKUP_HOME" ]; then
    info_kv "$(t "家目录备份" "home backup")" "$BACKUP_HOME" ""
fi
if [ -n "$BACKUP_ETC" ]; then
    info_kv "$(t "系统配置备份" "system backup")" "$BACKUP_ETC" ""
fi

exit 0
