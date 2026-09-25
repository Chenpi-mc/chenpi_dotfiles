#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 主控已经 export 了这三个变量；兜底只为让本模块单独跑时不被 set -u 炸掉。
export RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER="${TARGET_USER:-$(id -un)}"
export TARGET_HOME="${TARGET_HOME:-$HOME}"

# ==============================================================================
# 01a-base.sh — 基础系统配置（每步幂等，重跑安全）
#   1 系统更新+keyring  2 默认编辑器  3 multilib  4 字体
#   5 TTY 字体  6 locale  7 archlinuxcn  8 AUR 助手
# ==============================================================================

require_arch
section "$(t "基础系统配置" "Base system")" "$(t "更新 · 编辑器 · 字体 · locale · 社区源 · AUR" "update · editor · fonts · locale · repo · AUR")"

# --- 1. 系统更新 ---
# keyring 太旧会直接卡在 "invalid or corrupted package (PGP signature)"，先单独升它。
section "$(t "步骤 1/8" "Step 1/8")" "$(t "系统更新与 keyring" "Update & keyring")"

log "$(t "先更新 archlinux-keyring（避免 PGP 签名失败）" "Updating archlinux-keyring first (avoids PGP failures)")"
pac_install archlinux-keyring || true
if has_pkg archlinux-keyring; then
    success "$(t "archlinux-keyring 就绪" "archlinux-keyring ready")"
else
    warn "$(t "archlinux-keyring 没装上，后面装包可能签名失败" "archlinux-keyring missing; installs may fail on signatures")"
fi

# 一次 -Syu 对齐数据库和已装包，也让刚换的镜像源生效；不做单独的 -Sy（部分升级的坑）。
log "$(t "全量升级（-Syu）" "Full upgrade (-Syu)")"
if as_root pacman -Syu --noconfirm; then
    success "$(t "系统已对齐" "System up to date")"
else
    warn "$(t "升级失败，先继续，装包时可能报错" "Upgrade failed; continuing anyway")"
fi

# --- 2. 全局默认编辑器 ---
# 参考项目弹菜单选；这里简化成谁在就用谁，都没有才装 vim。
section "$(t "步骤 2/8" "Step 2/8")" "$(t "默认编辑器" "Default editor")"

TARGET_EDITOR=""
for _cand in nvim vim vi; do
    if command -v "$_cand" >/dev/null 2>&1; then
        TARGET_EDITOR="$_cand"
        break
    fi
done

if [ -z "$TARGET_EDITOR" ]; then
    log "$(t "没有 nvim/vim，装个 vim 兜底" "No nvim/vim, installing vim")"
    pac_install vim || true
    if command -v vim >/dev/null 2>&1; then
        TARGET_EDITOR="vim"
    fi
fi

if [ -z "$TARGET_EDITOR" ]; then
    warn "$(t "编辑器还是没装上，跳过 EDITOR 设置" "No editor available; skipping EDITOR")"
else
    info_kv "$(t "选用的编辑器" "Editor")" "$TARGET_EDITOR" "$(t "自动检测" "auto-detected")"

    if as_root grep -q '^EDITOR=' /etc/environment 2>/dev/null; then
        if as_root grep -q "^EDITOR=${TARGET_EDITOR}$" /etc/environment 2>/dev/null; then
            success "$(t "/etc/environment 里 EDITOR 已是 $TARGET_EDITOR" "/etc/environment already has EDITOR=$TARGET_EDITOR")"
        else
            as_root sed -i "s|^EDITOR=.*|EDITOR=${TARGET_EDITOR}|" /etc/environment
            success "$(t "/etc/environment 的 EDITOR 改为 $TARGET_EDITOR" "EDITOR in /etc/environment set to $TARGET_EDITOR")"
        fi
    else
        printf 'EDITOR=%s\n' "$TARGET_EDITOR" | as_root tee -a /etc/environment >/dev/null
        success "$(t "已写入 EDITOR=$TARGET_EDITOR" "Wrote EDITOR=$TARGET_EDITOR")"
    fi
fi

# --- 3. multilib 仓库（32 位包，wine / 游戏 / 部分 AUR 依赖它） ---
section "$(t "步骤 3/8" "Step 3/8")" "$(t "multilib 仓库" "multilib repo")"

if grep -q '^\[multilib\]' /etc/pacman.conf; then
    success "$(t "[multilib] 已启用，跳过" "[multilib] already enabled, skipping")"
else
    log "$(t "在 /etc/pacman.conf 里取消注释 [multilib] 及 Include 行" "Uncommenting [multilib] and its Include line")"
    as_root sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

    if grep -q '^\[multilib\]' /etc/pacman.conf; then
        success "$(t "[multilib] 已启用" "[multilib] enabled")"
        # 新增仓库后要 -Syu 对齐，单独 -Sy 就是部分升级
        log "$(t "刷新数据库并全量对齐" "Syncing database and upgrading")"
        if ! as_root pacman -Syu --noconfirm; then
            warn "$(t "刷新失败，装 32 位包时可能找不到目标" "Sync failed; 32-bit packages may be missing")"
        fi
    else
        warn "$(t "没改成功，请手动确认 [multilib] 段落" "Edit failed; check the [multilib] section manually")"
    fi
fi

# --- 4. 字体 ---
section "$(t "步骤 4/8" "Step 4/8")" "$(t "字体（中文 + 等宽 + emoji）" "fonts (CJK + mono + emoji)")"

# 中文用思源黑/宋（niri + kitty 下字重正常）；noto-cjk 兜生僻字，
# noto-emoji 防豆腐块，nerd 字体给终端和状态栏的图标字形。
log "$(t "安装中文字体与基础字体" "Installing CJK and base fonts")"
pac_install \
    adobe-source-han-sans-cn-fonts \
    adobe-source-han-serif-cn-fonts \
    ttf-liberation \
    noto-fonts \
    noto-fonts-cjk \
    noto-fonts-emoji \
    ttf-jetbrains-mono-nerd \
    otf-font-awesome \
    terminus-font || true

log "$(t "刷新字体缓存" "Refreshing font cache")"
if command -v fc-cache >/dev/null 2>&1; then
    as_root fc-cache -f >/dev/null 2>&1 || true
    as_user fc-cache -f >/dev/null 2>&1 || true
fi
success "$(t "字体就绪" "Fonts ready")"

# --- 5. TTY 控制台字体 ---
section "$(t "步骤 5/8" "Step 5/8")" "$(t "TTY 控制台字体" "TTY console font")"

if [ -f /etc/vconsole.conf ] && grep -q '^FONT=' /etc/vconsole.conf; then
    if grep -q '^FONT=ter-v28n' /etc/vconsole.conf; then
        success "$(t "vconsole.conf 的字体已是 ter-v28n" "vconsole.conf already uses ter-v28n")"
    else
        as_root sed -i 's|^FONT=.*|FONT=ter-v28n|' /etc/vconsole.conf
        success "$(t "vconsole.conf 的字体改为 ter-v28n" "vconsole.conf font set to ter-v28n")"
    fi
else
    printf 'FONT=ter-v28n\n' | as_root tee -a /etc/vconsole.conf >/dev/null
    success "$(t "已写入 FONT=ter-v28n" "Wrote FONT=ter-v28n")"
fi

# 在图形终端里 setfont 必然失败，忽略就好。
CUR_TTY="$(tty 2>/dev/null || true)"
case "$CUR_TTY" in
    /dev/tty[0-9]*)
        if as_root setfont ter-v28n 2>/dev/null; then
            success "$(t "当前控制台字体已切到 ter-v28n" "Console font switched to ter-v28n")"
        else
            warn "$(t "setfont 失败，重启后由 vconsole.conf 接管" "setfont failed; vconsole.conf applies after reboot")"
        fi
        ;;
    *)
        log "$(t "不在 TTY 控制台（${CUR_TTY:-$(t "未知" "unknown")}），跳过即时生效" "Not on a TTY (${CUR_TTY:-$(t "未知" "unknown")}); skipping live switch")"
        ;;
esac

log "$(t "让 systemd-vconsole-setup 重读配置" "Re-reading config via systemd-vconsole-setup")"
as_root systemctl restart systemd-vconsole-setup >/dev/null 2>&1 || true

# --- 6. locale（目标是中文环境） ---
section "$(t "步骤 6/8" "Step 6/8")" "$(t "locale（zh_CN.UTF-8）" "locale (zh_CN.UTF-8)")"

NEED_GENERATE=0

# en_US.UTF-8 给构建脚本兜底，zh_CN.UTF-8 日常用，两个都要。
for _loc in en_US.UTF-8 zh_CN.UTF-8; do
    # locale -a 显示成 zh_CN.utf8，只比前半段
    if locale -a 2>/dev/null | grep -qi "${_loc/UTF-8/utf8}"; then
        success "$(t "$_loc 已经生成好了" "$_loc already generated")"
        continue
    fi

    log "$(t "$_loc 未生成，先在 /etc/locale.gen 启用" "Enabling $_loc in /etc/locale.gen")"
    # locale.gen 里是 "zh_CN.UTF-8 UTF-8"，去掉行首 # 即可（已启用则无变化）
    as_root sed -i -E "s|^#[[:space:]]*(${_loc//./\\.}[[:space:]]+UTF-8)|\1|" /etc/locale.gen

    if grep -qE "^[[:space:]]*${_loc//./\\.}[[:space:]]+UTF-8" /etc/locale.gen; then
        success "$(t "$_loc 已在 /etc/locale.gen 中启用" "$_loc enabled in /etc/locale.gen")"
        NEED_GENERATE=1
    else
        warn "$(t "/etc/locale.gen 里找不到 $_loc 这一行，跳过" "No $_loc line in /etc/locale.gen, skipping")"
    fi
done

if [ "$NEED_GENERATE" -eq 1 ]; then
    log "$(t "生成 locale（可能要几十秒）" "Generating locale (may take a while)")"
    if as_root locale-gen; then
        success "$(t "locale 生成完成" "locale generated")"
    else
        warn "$(t "locale-gen 失败，检查一下 /etc/locale.gen" "locale-gen failed; check /etc/locale.gen")"
    fi
else
    success "$(t "locale 都是现成的，不用重新生成" "locales already present, nothing to generate")"
fi

# 只在 LANG 没设或为 C/POSIX 时写，不覆盖用户特意设过的值（比如故意用英文界面）
CUR_LANG="$(as_root sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | head -n 1 || true)"
if [ -z "${CUR_LANG:-}" ] || [ "$CUR_LANG" = "C" ] || [ "$CUR_LANG" = "POSIX" ]; then
    log "$(t "把 /etc/locale.conf 的 LANG 设为 zh_CN.UTF-8" "Setting LANG=zh_CN.UTF-8 in /etc/locale.conf")"
    if as_root grep -q '^LANG=' /etc/locale.conf 2>/dev/null; then
        as_root sed -i 's|^LANG=.*|LANG=zh_CN.UTF-8|' /etc/locale.conf
    else
        printf 'LANG=zh_CN.UTF-8\n' | as_root tee -a /etc/locale.conf >/dev/null
    fi
    success "$(t "默认语言 = zh_CN.UTF-8（重新登录后生效）" "Default language = zh_CN.UTF-8 (on re-login)")"
else
    info_kv "$(t "默认语言" "Default language")" "$CUR_LANG" "$(t "保持不动" "left as is")"
fi

# --- 7. archlinuxcn 社区源 ---
section "$(t "步骤 7/8" "Step 7/8")" "$(t "archlinuxcn 社区源" "archlinuxcn repo")"

# 用它是因为 yay / paru / archlinuxcn-keyring 现成（ensure_aur_helper 也会先看源）。
# 公共社区源，不是 shorin 的私有源；不写 USTC（超时）和 QLU（404）。
if grep -q '^\[archlinuxcn\]' /etc/pacman.conf; then
    success "$(t "[archlinuxcn] 已经配置过了，不重复追加" "[archlinuxcn] already configured, skipping")"
else
    log "$(t "追加 [archlinuxcn] 到 /etc/pacman.conf（先备份 pacman.conf）" "Appending [archlinuxcn] (pacman.conf backed up first)")"
    as_root cp -a /etc/pacman.conf /etc/pacman.conf.chenpi.bak
    as_root tee -a /etc/pacman.conf >/dev/null <<'EOT'

[archlinuxcn]
Server = https://repo.archlinuxcn.org/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch
Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
EOT
    success "$(t "[archlinuxcn] 已加入（备份：/etc/pacman.conf.chenpi.bak）" "[archlinuxcn] added (backup: /etc/pacman.conf.chenpi.bak)")"
fi

# 新源要同步数据库 pacman 才认得（-Syu 顺带避免部分升级）
log "$(t "同步数据库" "Syncing database")"
if ! as_root pacman -Syu --noconfirm; then
    warn "$(t "同步 / 升级失败，archlinuxcn 的包可能装不上" "Sync failed; archlinuxcn packages may be unavailable")"
fi

# keyring 不装的话，archlinuxcn 的包会卡在签名验证
log "$(t "安装 archlinuxcn-keyring" "Installing archlinuxcn-keyring")"
pac_install archlinuxcn-keyring || true
if has_pkg archlinuxcn-keyring; then
    success "$(t "archlinuxcn-keyring 就绪" "archlinuxcn-keyring ready")"
else
    warn "$(t "archlinuxcn-keyring 没装上，包会签名失败" "archlinuxcn-keyring missing; signature checks will fail")"
fi

# --- 8. AUR 助手 ---
section "$(t "步骤 8/8" "Step 8/8")" "$(t "AUR 助手" "AUR helper")"

# 交给 ensure_aur_helper：先看已配置的源，真没有才从 AUR 自举 yay-bin，
# 并处理 makepkg 不许用 root（root 跑时切回 TARGET_USER）。
ensure_aur_helper
if [ -n "${AUR_HELPER:-}" ]; then
    success "$(t "AUR 助手可用：$AUR_HELPER" "AUR helper ready: $AUR_HELPER")"
else
    warn "$(t "没弄到 AUR 助手，AUR 包会被跳过（重跑会自动补）" "No AUR helper; AUR packages skipped (re-run to retry)")"
fi

# --- 收尾 ---
section "$(t "01a 完成" "01a done")" "$(t "基础配置汇总" "Summary")"
info_kv "$(t "编辑器" "Editor")" "${TARGET_EDITOR:-$(t "未设置" "unset")}"
info_kv "$(t "locale" "locale")" "en_US.UTF-8 + zh_CN.UTF-8"
info_kv "$(t "默认语言" "Default language")" "$(as_root sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | head -n 1 || true)"
info_kv "$(t "AUR 助手" "AUR helper")" "${AUR_HELPER:-$(t "无" "none")}"
info_kv "$(t "日志" "Log")" "$LOG_FILE"
success "$(t "基础系统配置完成" "Base system configuration done")"
