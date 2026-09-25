#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 07-grub-theme.sh — 给 GRUB 换个主题
# 改写自 ref/shorin-arch-setup/scripts/07-grub-theme.sh（AGPL-3.0）
#
# 和参考版的区别（很重要）：
#   * 参考版从仓库自带的 resources/grub-themes/ 里拷主题，我们仓库没有这些资源
#     也不引用 resources/，所以改成“装一个主题包 / 用系统里现成的主题”。
#   * 参考版还顺手删 quiet / splash 内核参数、加 Shutdown / Reboot 菜单项、清 minegrub。
#     那些跟主题无关，而且启动参数改错会进不去系统 —— 这里一律不碰，只干主题这一件事。
#
# 步骤：
#   0. 不是 GRUB 引导（systemd-boot / UKI）→ 整个模块跳过，exit 0
#   1. 找现成主题（/boot/grub/themes、/usr/share/grub/themes），没有才装主题包
#   2. 定下 theme.txt 的最终路径（/boot 单独分区时要拷进 /boot，GRUB 才读得到）
#   3. 改 /etc/default/grub 的 GRUB_THEME=（改前备份），必要时补 GRUB_GFXMODE
#   4. grub-mkconfig -o /boot/grub/grub.cfg
# ==============================================================================

# 主题包：首选 Arch 官方源（extra）的 grub-theme-vimix
#   → 已确认包存在，装到 /usr/share/grub/themes/Vimix/theme.txt，不用编译，最省事
# AUR 兜底：grub-themes-git 的 split 包（grub-theme-vimix-*-git 那一串，已确认存在），
#   只有“已配置的源里查不到官方包”时才会去试
# 想换主题：GRUB_THEME_REPO_PKG=xxx ./install.sh，或者直接改下面两行
GRUB_THEME_REPO_PKG="${GRUB_THEME_REPO_PKG:-grub-theme-vimix}"
GRUB_THEME_AUR_PKG="${GRUB_THEME_AUR_PKG:-grub-theme-vimix-color-1080p-git}"
GRUB_CONF="/etc/default/grub"
STAMP="$(date +%Y%m%d-%H%M%S)"

require_arch

# ------------------------------------------------------------------------------
# 0. 先确认这台机器真的是 GRUB 引导
# ------------------------------------------------------------------------------
section "第 0 步" "确认引导方式"

# /boot/grub/grub.cfg 不存在，说明引导器不是 GRUB（systemd-boot / UKI / rEFInd）。
# 这种情况下改 /etc/default/grub 毫无意义，只会留一堆没人读的垃圾配置，所以直接跳过。
if [ ! -f /boot/grub/grub.cfg ]; then
    warn "找不到 /boot/grub/grub.cfg —— 这台机器不是 GRUB 引导（systemd-boot / UKI 之类）"
    log "跳过 GRUB 主题配置（对启动没有任何影响，什么都不用管）"
    exit 0
fi

# 有些系统引导用 GRUB 但工具被精简掉了，那样也配不了
if ! command -v grub-mkconfig >/dev/null 2>&1; then
    warn "找不到 grub-mkconfig（grub 工具没装全），跳过"
    log "想配主题的话先补上：sudo pacman -S grub"
    exit 0
fi

success "确认是 GRUB 引导，可以配主题"

# ------------------------------------------------------------------------------
# 1. 找现成主题，没有就装一个
# ------------------------------------------------------------------------------
section "第 1 步" "准备主题文件"

# 两个候选目录：
#   /boot/grub/themes      —— 在 GRUB 自己的 prefix 里，一定读得到（优先用这个）
#   /usr/share/grub/themes —— Arch 官方主题包（含 grub 自带的 starfield）装的地方
THEME_SEARCH_DIRS=(/boot/grub/themes /usr/share/grub/themes)
THEME_DIR=""
THEME_NAME=""

# 扫主题目录：认“<目录>/theme.txt”这种结构，返回第一个（按路径排序，结果稳定）。
# 按 THEME_SEARCH_DIRS 的顺序扫，所以 /boot/grub/themes 里的主题优先。
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

# 把扫到的主题全列出来，让人一眼看清系统里都有啥（用哪个由上面的优先级决定）
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
    success "系统里已经有主题：$THEME_NAME（$THEME_DIR）"
    log "扫到的主题目录："
    list_themes
else
    warn "系统里没有任何 GRUB 主题（没用过主题，或者 themes 目录是空的）"

    # 首选官方源：能查到就不用碰 AUR，装出来的东西还能被 pacman 管着、跟着一起升级
    if pacman -Si "$GRUB_THEME_REPO_PKG" >/dev/null 2>&1; then
        log "从官方源装主题包：$GRUB_THEME_REPO_PKG"
        # pac_install 内部 --needed（已装就跳过），并自动登记到 $VERIFY_LIST 给 05-verify 对账
        pac_install "$GRUB_THEME_REPO_PKG"
    else
        warn "已配置的源里没有 $GRUB_THEME_REPO_PKG，改试 AUR：$GRUB_THEME_AUR_PKG"
        log "AUR 要现场编译，慢一点；没有 AUR 助手的话这一步会自己跳过"
        aur_install "$GRUB_THEME_AUR_PKG" || true
    fi

    # 装完重新扫一次（官方包一般落到 /usr/share/grub/themes/<名字>/theme.txt）
    if find_theme; then
        success "主题装好了：$THEME_NAME（$THEME_DIR）"
    else
        warn "还是没找到可用的主题目录，这次就不配主题了"
        log "手动装法：sudo pacman -S $GRUB_THEME_REPO_PKG"
        log "         或者 yay -S $GRUB_THEME_AUR_PKG（AUR split 包，任选一个）"
        log "装完重跑 ./install.sh，本模块会认出它并自动配好"
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# 2. 定下 theme.txt 的最终路径
# ------------------------------------------------------------------------------
section "第 2 步" "确定 theme.txt 路径"

THEME_TXT="$THEME_DIR/theme.txt"

# GRUB 运行时只能读它自己那个 prefix（一般就是 /boot 所在的那块文件系统）。
# 如果 /boot 是单独的分区（或单独的 btrfs 子卷），主题放在 root 的
# /usr/share/grub/themes 下，GRUB 根本看不到背景图 —— 界面会退回纯文本。
# 所以这种情况把主题整个目录拷一份进 /boot/grub/themes。
# theme.txt 里引用图片都是相对路径，必须整目录拷，只拷 theme.txt 没用。
if [ "$THEME_DIR" != "/boot/grub/themes/$THEME_NAME" ]; then
    # /boot 是单独挂载点 → findmnt 会输出它的挂载点；/boot 和 / 同一个文件系统 → 空
    BOOT_MNT="$(findmnt -no TARGET /boot 2>/dev/null || true)"
    if [ -n "$BOOT_MNT" ]; then
        log "/boot 是单独挂载的（$BOOT_MNT），GRUB 读不到 $THEME_DIR，拷一份进去"
        if [ -f "/boot/grub/themes/$THEME_NAME/theme.txt" ]; then
            log "目标位置已经有同名主题了，不重复拷（保证幂等）"
        else
            as_root mkdir -p /boot/grub/themes
            as_root cp -a "$THEME_DIR" /boot/grub/themes/ \
                || warn "拷贝失败（/boot 只读？），先继续用原来的路径"
        fi
        if [ -f "/boot/grub/themes/$THEME_NAME/theme.txt" ]; then
            THEME_TXT="/boot/grub/themes/$THEME_NAME/theme.txt"
        fi
    else
        log "/boot 和 root 在同一个文件系统上，GRUB 读得到，直接用原路径"
    fi
else
    log "主题本来就装在 $THEME_DIR，已经在 GRUB 的 prefix 里，不用拷"
fi

info_kv "主题名" "$THEME_NAME"
info_kv "theme.txt" "$THEME_TXT"

if [ ! -f "$THEME_TXT" ]; then
    warn "theme.txt 不在了（$THEME_TXT），跳过配置"
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. 改 /etc/default/grub
# ------------------------------------------------------------------------------
section "第 3 步" "配置 $GRUB_CONF"

if [ ! -f "$GRUB_CONF" ]; then
    warn "$GRUB_CONF 不存在 —— GRUB 机器一般都有这个文件，说明系统状态有点怪"
    log "跳过主题配置，需要的话手动建一个"
    exit 0
fi

# 往 /etc/default/grub 写一个 KEY="value"。
# 刻意做成“先删掉所有同名行（含被注释的），再在文件末尾追加一行”：
#   * 重复跑不会堆出一串 GRUB_THEME=，天然幂等
#   * GRUB 读这个文件不分先后，键挪到末尾没有任何影响
set_grub_key() {
    local key="$1" val="$2" esc
    esc="$(printf '%s' "$val" | sed 's/[\\&|]/\\&/g')"
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
    success "配置已经是想要的样子，不用改：$WANT_LINE"
else
    # 改系统文件之前先按时间戳备份一份，写坏了还能 cp 回来
    BACKUP_FILE="$GRUB_CONF.bak.$STAMP"
    as_root cp -a "$GRUB_CONF" "$BACKUP_FILE" || warn "备份失败，继续（下面的改动请自己留意）"
    info_kv "改前备份" "$BACKUP_FILE"

    if [ "$CURRENT_LINE" = "$WANT_LINE" ]; then
        log "GRUB_THEME 本来就是对的，跳过改写"
    else
        info_kv "原 GRUB_THEME" "${CURRENT_LINE:-（没有这一项）}"
        if set_grub_key "GRUB_THEME" "$THEME_TXT"; then
            success "GRUB_THEME 已指向 $THEME_TXT"
        else
            warn "写 GRUB_THEME 失败，检查 /etc/default/grub 的权限"
        fi
    fi

    # 图形主题要图形模式才显示。用户自己设过就不动，没设才补一个 auto
    if grep -qE '^GRUB_GFXMODE=' "$GRUB_CONF"; then
        log "GRUB_GFXMODE 已有设置，尊重现有值不动"
    else
        if set_grub_key "GRUB_GFXMODE" "auto"; then
            success "补上 GRUB_GFXMODE=auto（主题需要图形模式）"
        else
            warn "写 GRUB_GFXMODE 失败"
        fi
    fi

    # GRUB_TERMINAL_OUTPUT="console" 会强制纯文本输出，主题背景直接不显示 → 注释掉
    if grep -qE '^GRUB_TERMINAL_OUTPUT="console"' "$GRUB_CONF"; then
        if as_root sed -i -E 's|^GRUB_TERMINAL_OUTPUT="console"|#GRUB_TERMINAL_OUTPUT="console"|' "$GRUB_CONF"; then
            success "注释掉 GRUB_TERMINAL_OUTPUT=\"console\"（它会挡住主题）"
        else
            warn "注释 GRUB_TERMINAL_OUTPUT 失败，主题可能不显示背景"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 4. 生成 grub.cfg
# ------------------------------------------------------------------------------
section "第 4 步" "重新生成 /boot/grub/grub.cfg"

# grub-mkconfig 本身幂等（写临时文件再替换），所以配置没变也照样重建一次，
# 保证“主题刚装好但 grub.cfg 还是旧的”这种情况也能生效。
if exe as_root grub-mkconfig -o /boot/grub/grub.cfg; then
    success "grub.cfg 已更新，重启就能看到主题了"
else
    # 不把模块判为失败：旧的 grub.cfg 还在，系统照样能引导，
    # 而且 install.sh 收尾还会再跑一次 grub-mkconfig
    warn "grub-mkconfig 失败了 —— 先别急着重启"
    warn "旧的 grub.cfg 没被破坏，系统仍能正常引导"
    warn "手动跑一次看它报什么错：sudo grub-mkconfig -o /boot/grub/grub.cfg"
fi

section "完成" "GRUB 主题"
info_kv "主题" "$THEME_NAME"
info_kv "theme.txt" "$THEME_TXT"
if [ -n "$BACKUP_FILE" ]; then
    info_kv "改前备份" "$BACKUP_FILE" "想还原就 cp 回去再 grub-mkconfig"
else
    info_kv "配置改动" "无（本来就是这套配置）"
fi

exit 0
