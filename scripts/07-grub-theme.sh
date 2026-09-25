#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 07-grub-theme.sh — 给 GRUB 换个主题；改写自 ref/shorin-arch-setup（AGPL-3.0）
# 只干主题一件事：参考版还会删 quiet / splash 内核参数、改菜单项、清 minegrub，
# 那些跟主题无关，而且启动参数改错会进不去系统 —— 这里一律不碰。
# 流程：不是 GRUB 引导就整体跳过 → 找 / 装主题 → 定下 theme.txt 路径（/boot
# 单独分区时要拷进 /boot）→ 改 /etc/default/grub → grub-mkconfig。

# 主题包：官方源 extra 的 grub-theme-vimix（不用编译）；AUR 兜底
# grub-theme-vimix-color-1080p-git，只在源里查不到时才试。想换就改下面两行。
GRUB_THEME_REPO_PKG="${GRUB_THEME_REPO_PKG:-grub-theme-vimix}"
GRUB_THEME_AUR_PKG="${GRUB_THEME_AUR_PKG:-grub-theme-vimix-color-1080p-git}"
GRUB_CONF="/etc/default/grub"
STAMP="$(date +%Y%m%d-%H%M%S)"

require_arch

# ---- 0. 确认是 GRUB 引导 ----
log "$(t "第 0 步：确认引导方式" "step 0: detect bootloader")"

# /boot/grub/grub.cfg 不存在说明引导器不是 GRUB（systemd-boot / UKI / rEFInd）。
# 这时改 /etc/default/grub 毫无意义，只会留一堆没人读的垃圾配置 → 直接跳过。
if [ ! -f /boot/grub/grub.cfg ]; then
    warn "$(t "不是 GRUB 引导（systemd-boot / UKI 之类）" "not GRUB (systemd-boot / UKI?)")"
    log "$(t "跳过 GRUB 主题，对启动没有任何影响" "skipping GRUB theme, no effect on boot")"
    exit 0
fi

# 引导用 GRUB 但工具被精简掉了，同样配不了
if ! command -v grub-mkconfig >/dev/null 2>&1; then
    warn "$(t "找不到 grub-mkconfig，grub 工具没装全" "grub-mkconfig missing, grub tools incomplete")"
    log "$(t "缺 grub，装完重跑：sudo pacman -S --needed grub" "install grub and rerun: sudo pacman -S --needed grub")"
    exit 0
fi

success "$(t "确认是 GRUB 引导" "GRUB detected")"

# ---- 1. 找现成主题，没有就装一个 ----
log "$(t "第 1 步：准备主题文件" "step 1: prepare theme files")"

# 两个候选目录：/boot/grub/themes（在 GRUB 的 prefix 里，一定读得到，优先用）、
# /usr/share/grub/themes（官方主题包和 grub 自带 starfield 装的地方）
THEME_SEARCH_DIRS=(/boot/grub/themes /usr/share/grub/themes)
THEME_DIR=""
THEME_NAME=""

# 认“<目录>/theme.txt”结构，按目录顺序扫，返回第一个（排序过，结果稳定）
find_theme() {
    local d t
    for d in "${THEME_SEARCH_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            THEME_DIR="$(dirname "$t")"
            THEME_NAME="$(basename "$THEME_DIR")"
            return 0
        done < <(find "$d" -mindepth 2 -maxdepth 2 -name theme.txt 2>/dev/null | sort)
    done
    return 1
}

# 把扫到的主题全列出来，用哪个由上面的优先级决定
list_themes() {
    local d t
    for d in "${THEME_SEARCH_DIRS[@]}"; do
        [ -d "$d" ] || continue
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            echo -e "       $TICK ${H_CYAN}$(dirname "$t")${NC}"
        done < <(find "$d" -mindepth 2 -maxdepth 2 -name theme.txt 2>/dev/null | sort)
    done
}

if find_theme; then
    success "$(t "系统里已经有主题：$THEME_NAME（$THEME_DIR）" "theme found: $THEME_NAME ($THEME_DIR)")"
    log "$(t "扫到的主题目录：" "themes found:")"
    list_themes
else
    warn "$(t "系统里没有任何 GRUB 主题" "no GRUB theme found")"

    # 首选官方源：被 pacman 管着、跟着一起升级，也不用碰 AUR
    if pacman -Si "$GRUB_THEME_REPO_PKG" >/dev/null 2>&1; then
        log "$(t "从官方源装主题包：$GRUB_THEME_REPO_PKG" "installing from repo: $GRUB_THEME_REPO_PKG")"
        # pac_install 内部 --needed（已装就跳过），并自动登记到 $VERIFY_LIST 给 05-verify
        pac_install "$GRUB_THEME_REPO_PKG"
    else
        warn "$(t "源里没有 $GRUB_THEME_REPO_PKG，改试 AUR" "not in repo, trying AUR: $GRUB_THEME_AUR_PKG")"
        log "$(t "AUR 要现场编译，慢一点；没有 AUR 助手会自己跳过" "AUR builds from source, slower; skipped without a helper")"
        aur_install "$GRUB_THEME_AUR_PKG" || true
    fi

    # 装完重新扫一次（官方包一般落到 /usr/share/grub/themes/<名字>/theme.txt）
    if find_theme; then
        success "$(t "主题装好了：$THEME_NAME（$THEME_DIR）" "theme installed: $THEME_NAME ($THEME_DIR)")"
    else
        warn "$(t "还是没找到可用的主题，这次不配了" "still no usable theme, skipping")"
        log "$(t "手动装：sudo pacman -S --needed $GRUB_THEME_REPO_PKG" "manual: sudo pacman -S --needed $GRUB_THEME_REPO_PKG")"
        log "$(t "或者 yay -S $GRUB_THEME_AUR_PKG（任选一个）" "or yay -S $GRUB_THEME_AUR_PKG (either one)")"
        log "$(t "装完重跑 ./install.sh，会自动配好" "then rerun ./install.sh")"
        exit 0
    fi
fi

# ---- 2. 定下 theme.txt 的最终路径 ----
log "$(t "第 2 步：确定 theme.txt 路径" "step 2: resolve theme.txt path")"

THEME_TXT="$THEME_DIR/theme.txt"

# GRUB 只读得到自己的 prefix（一般就是 /boot 那块文件系统）。/boot 单独分区（或
# 单独 btrfs 子卷）时，留在 root 下的主题 GRUB 根本看不见，界面会退回纯文本 →
# 整目录拷一份进 /boot/grub/themes（图片是相对路径，只拷 theme.txt 没用）。
if [ "$THEME_DIR" != "/boot/grub/themes/$THEME_NAME" ]; then
    # /boot 是单独挂载点 → findmnt 输出它的挂载点；和 / 同一文件系统 → 空
    BOOT_MNT="$(findmnt -no TARGET /boot 2>/dev/null || true)"
    if [ -n "$BOOT_MNT" ]; then
        log "$(t "/boot 单独挂载（$BOOT_MNT），GRUB 读不到，拷一份进去" "/boot is a separate mount ($BOOT_MNT), copying theme in")"
        if [ -f "/boot/grub/themes/$THEME_NAME/theme.txt" ]; then
            log "$(t "目标位置已有同名主题，不重复拷（幂等）" "theme already there, skipping (idempotent)")"
        else
            as_root mkdir -p /boot/grub/themes
            as_root cp -a "$THEME_DIR" /boot/grub/themes/ \
                || warn "$(t "拷贝失败（/boot 只读？），先用原路径" "copy failed (/boot read-only?), keeping original path")"
        fi
        if [ -f "/boot/grub/themes/$THEME_NAME/theme.txt" ]; then
            THEME_TXT="/boot/grub/themes/$THEME_NAME/theme.txt"
        fi
    else
        log "$(t "/boot 和 root 同一文件系统，GRUB 读得到，用原路径" "/boot shares root fs, using original path")"
    fi
else
    log "$(t "主题已在 GRUB 的 prefix 里，不用拷" "theme already in GRUB prefix")"
fi

log "$(t "主题名：$THEME_NAME" "theme name: $THEME_NAME")"
log "$(t "主题文件：$THEME_TXT" "theme file: $THEME_TXT")"

if [ ! -f "$THEME_TXT" ]; then
    warn "$(t "theme.txt 不在了，跳过配置" "theme.txt is gone, skipping")"
    exit 0
fi

# ---- 3. 改 /etc/default/grub ----
log "$(t "第 3 步：配置 $GRUB_CONF" "step 3: edit $GRUB_CONF")"

if [ ! -f "$GRUB_CONF" ]; then
    warn "$(t "$GRUB_CONF 不存在 —— GRUB 机器一般都有，系统状态有点怪" "$GRUB_CONF missing, system looks odd")"
    log "$(t "跳过主题配置，需要的话手动建一个" "skipping; create it by hand if needed")"
    exit 0
fi

# 写 KEY="value"：先删掉所有同名行（含被注释的）再在末尾追加 —— 重复跑不会
# 堆出一串 GRUB_THEME=，天然幂等；GRUB 读这个文件不分先后，键挪末尾没有影响。
set_grub_key() {
    local key="$1" val="$2" esc
    # 赋值里带管道：printf / sed 一旦失败，pipefail + set -e 会把脚本带走 → || true
    esc="$(printf '%s' "$val" | sed 's/[\\&|]/\\&/g' || true)"
    as_root sed -i -E "/^#?[[:space:]]*${key}=/d" "$GRUB_CONF"
    as_root sed -i -e "\$a ${key}=\"${esc}\"" "$GRUB_CONF"
}

WANT_LINE="GRUB_THEME=\"$THEME_TXT\""
CURRENT_LINE="$(grep -E '^GRUB_THEME=' "$GRUB_CONF" | tail -n 1 || true)"

# 先判断到底要不要动这个文件 —— 不用动就不备份，免得反复跑攒一堆 .bak
NEED_CHANGE=0
if [ "$CURRENT_LINE" != "$WANT_LINE" ]; then NEED_CHANGE=1; fi
if ! grep -qE '^GRUB_GFXMODE=' "$GRUB_CONF"; then NEED_CHANGE=1; fi
if grep -qE '^GRUB_TERMINAL_OUTPUT="console"' "$GRUB_CONF"; then NEED_CHANGE=1; fi

BACKUP_FILE=""
if [ "$NEED_CHANGE" -eq 0 ]; then
    success "$(t "配置已经是想要的样子，不用改：$WANT_LINE" "config already correct: $WANT_LINE")"
else
    # 改系统文件之前先按时间戳备份一份，写坏了还能 cp 回来
    BACKUP_FILE="$GRUB_CONF.bak.$STAMP"
    as_root cp -a "$GRUB_CONF" "$BACKUP_FILE" || warn "$(t "备份失败，继续（下面的改动请自己留意）" "backup failed, continuing (mind the changes)")"
    log "$(t "改前备份：$BACKUP_FILE" "backup before edit: $BACKUP_FILE")"

    if [ "$CURRENT_LINE" = "$WANT_LINE" ]; then
        log "$(t "GRUB_THEME 本来就是对的，跳过改写" "GRUB_THEME already correct")"
    else
        log "$(t "原 GRUB_THEME：${CURRENT_LINE:-（没设）}" "old GRUB_THEME: ${CURRENT_LINE:-not set}")"
        if set_grub_key "GRUB_THEME" "$THEME_TXT"; then
            success "$(t "GRUB_THEME 已指向 $THEME_TXT" "GRUB_THEME -> $THEME_TXT")"
        else
            warn "$(t "写 GRUB_THEME 失败，检查 /etc/default/grub 权限" "writing GRUB_THEME failed, check permissions")"
        fi
    fi

    # 图形主题要图形模式才显示；用户自己设过就不动，没设才补一个 auto
    if grep -qE '^GRUB_GFXMODE=' "$GRUB_CONF"; then
        log "$(t "GRUB_GFXMODE 已有设置，尊重现有值不动" "GRUB_GFXMODE already set, leaving it")"
    else
        if set_grub_key "GRUB_GFXMODE" "auto"; then
            success "$(t "补上 GRUB_GFXMODE=auto（主题要图形模式）" "added GRUB_GFXMODE=auto")"
        else
            warn "$(t "写 GRUB_GFXMODE 失败" "writing GRUB_GFXMODE failed")"
        fi
    fi

    # GRUB_TERMINAL_OUTPUT="console" 强制纯文本输出，主题背景直接不显示 → 注释掉
    if grep -qE '^GRUB_TERMINAL_OUTPUT="console"' "$GRUB_CONF"; then
        if as_root sed -i -E 's|^GRUB_TERMINAL_OUTPUT="console"|#GRUB_TERMINAL_OUTPUT="console"|' "$GRUB_CONF"; then
            success "$(t "已注释 GRUB_TERMINAL_OUTPUT=console（它会挡住主题）" "commented out GRUB_TERMINAL_OUTPUT (it hides themes)")"
        else
            warn "$(t "注释 GRUB_TERMINAL_OUTPUT 失败，主题可能没背景" "failed to comment it out, theme may lack background")"
        fi
    fi
fi

# ---- 4. 生成 grub.cfg ----
log "$(t "第 4 步：重新生成 grub.cfg" "step 4: regenerate grub.cfg")"

# grub-mkconfig 本身幂等，配置没变也照样重建一次，保证 grub.cfg 不会留在旧状态
if exe as_root grub-mkconfig -o /boot/grub/grub.cfg; then
    success "$(t "grub.cfg 已更新，重启就能看到主题" "grub.cfg updated, reboot to see the theme")"
else
    # 不判失败：旧 grub.cfg 还在，系统照样能引导，install.sh 收尾还会再跑一次
    warn "$(t "grub-mkconfig 失败 —— 先别急着重启" "grub-mkconfig failed, do not reboot yet")"
    warn "$(t "旧的 grub.cfg 没被破坏，系统仍能正常引导" "old grub.cfg intact, system still boots")"
    warn "$(t "手动跑一次看报错：sudo grub-mkconfig -o /boot/grub/grub.cfg" "run it manually: sudo grub-mkconfig -o /boot/grub/grub.cfg")"
fi

log "$(t "完成：GRUB 主题" "done: GRUB theme")"
log "$(t "主题：$THEME_NAME" "theme: $THEME_NAME")"
log "$(t "主题文件：$THEME_TXT" "theme file: $THEME_TXT")"
if [ -n "$BACKUP_FILE" ]; then
    log "$(t "改前备份：$BACKUP_FILE（还原就 cp 回去再 grub-mkconfig）" "backup: $BACKUP_FILE (restore: cp back and run grub-mkconfig)")"
else
    log "$(t "配置改动：无（本来就是这套配置）" "changes: none (already correct)")"
fi

exit 0
