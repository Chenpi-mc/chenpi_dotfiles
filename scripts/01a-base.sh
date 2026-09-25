#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# 主控已经 export 了这三个变量；兜底只是为了让本模块能单独跑（set -u 不炸）。
export RUN_AS_ROOT="${RUN_AS_ROOT:-0}"
export TARGET_USER="${TARGET_USER:-$(id -un)}"
export TARGET_HOME="${TARGET_HOME:-$HOME}"

# ==============================================================================
# 01a-base.sh — 基础系统配置
# 改写自 ref/shorin-arch-setup/scripts/01a-base.sh
#
# 每一步都是幂等的（重跑只会重复"已经是这样了"的检查，不会把系统搞坏）：
#   1. 系统更新：先升 archlinux-keyring，再 -Syu 全量对齐
#   2. 全局编辑器：自动挑 nvim/vim 写进 /etc/environment（不弹交互菜单）
#   3. multilib：没开才开
#   4. 字体：思源黑/宋（中文）+ Liberation + emoji + 等宽
#   5. TTY 字体：terminus 的 ter-v28n
#   6. locale：en_US.UTF-8 + zh_CN.UTF-8（中文环境）
#   7. archlinuxcn 社区源 + archlinuxcn-keyring
#   8. AUR 助手：交给 00-utils 的 ensure_aur_helper
#
# 和参考项目的区别（他私有 / 不合适照搬的东西一律不要）：
#   - 不强制 root，改系统的动作走 as_root，碰家目录的走 as_user
#   - 不写他的 [shorin-arch] 源、不装他的桌面变体、不碰 resources/
#   - 编辑器从"交互菜单"简化成"检测到就用"
#   - 装包统一走 pac_install / aur_install，会自动登记到对账清单
# ==============================================================================

require_arch
section "基础系统配置" "更新 · 编辑器 · 字体 · locale · 社区源 · AUR 助手"

# ------------------------------------------------------------------------------
# 1. 系统更新
# ------------------------------------------------------------------------------
# 先单独升 archlinux-keyring：源里新包的签名可能是新 key 签的，
# keyring 太旧会直接卡在 "invalid or corrupted package (PGP signature)"。
section "步骤 1/8" "系统更新与 keyring"

log "先更新 archlinux-keyring（避免后面装包报 PGP 签名失败）"
pac_install archlinux-keyring || true
if has_pkg archlinux-keyring; then
    success "archlinux-keyring 就绪"
else
    warn "archlinux-keyring 没装上，后面装包可能因为签名问题失败"
fi

# 一次 -Syu 把数据库和已装包对齐，顺便让刚换的镜像源真正生效。
# 不做 -Sy 单独刷库（那是"部分升级"的经典踩坑方式）。
log "全量升级（-Syu）"
if as_root pacman -Syu --noconfirm; then
    success "系统已对齐"
else
    warn "系统更新失败（网络 / 源的问题），先继续，装包时可能报错"
fi

# ------------------------------------------------------------------------------
# 2. 全局默认编辑器
# ------------------------------------------------------------------------------
# 参考项目是弹菜单让人选；这里简化：谁在就用谁，都没有才装 vim。
section "步骤 2/8" "全局默认编辑器"

TARGET_EDITOR=""
for _cand in nvim vim vi; do
    if command -v "$_cand" >/dev/null 2>&1; then
        TARGET_EDITOR="$_cand"
        break
    fi
done

if [ -z "$TARGET_EDITOR" ]; then
    log "系统里没有 nvim/vim，装一个 vim 兜底"
    pac_install vim || true
    if command -v vim >/dev/null 2>&1; then
        TARGET_EDITOR="vim"
    fi
fi

if [ -z "$TARGET_EDITOR" ]; then
    warn "编辑器还是没装上，跳过 EDITOR 设置（不影响其它步骤）"
else
    info_kv "选用的编辑器" "$TARGET_EDITOR" "自动检测，不弹菜单"

    if as_root grep -q '^EDITOR=' /etc/environment 2>/dev/null; then
        if as_root grep -q "^EDITOR=${TARGET_EDITOR}$" /etc/environment 2>/dev/null; then
            success "/etc/environment 里的 EDITOR 已经是 $TARGET_EDITOR，无需改动"
        else
            as_root sed -i "s|^EDITOR=.*|EDITOR=${TARGET_EDITOR}|" /etc/environment
            success "/etc/environment 的 EDITOR 已改为 $TARGET_EDITOR"
        fi
    else
        printf 'EDITOR=%s\n' "$TARGET_EDITOR" | as_root tee -a /etc/environment >/dev/null
        success "/etc/environment 写入 EDITOR=$TARGET_EDITOR"
    fi
fi

# ------------------------------------------------------------------------------
# 3. multilib 仓库（32 位包，很多 AUR / 游戏 / wine 依赖要它）
# ------------------------------------------------------------------------------
section "步骤 3/8" "multilib 仓库"

if grep -q '^\[multilib\]' /etc/pacman.conf; then
    success "[multilib] 已经是启用状态（CachyOS 默认就开着），跳过"
else
    log "在 /etc/pacman.conf 里打开被注释掉的 [multilib] 与它的 Include 行"
    as_root sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf

    if grep -q '^\[multilib\]' /etc/pacman.conf; then
        success "[multilib] 已启用"
        log "新增仓库后刷新数据库并做一次全量对齐（避免部分升级）"
        if ! as_root pacman -Syu --noconfirm; then
            warn "刷新失败，装 32 位包时可能提示找不到目标"
        fi
    else
        warn "没改成功（/etc/pacman.conf 结构可能被改过），请手动确认 [multilib] 段落"
    fi
fi

# ------------------------------------------------------------------------------
# 4. 字体
# ------------------------------------------------------------------------------
section "步骤 4/8" "字体（中文 + 等宽 + emoji）"

# 中文字体用 Adobe 思源黑/宋：niri + kitty 下字形和字重都正常。
# noto-fonts-cjk / noto-fonts-emoji 作为兜底，防止生僻字和 emoji 变豆腐块。
# ttf-jetbrains-mono-nerd 给终端和状态栏的图标字形用（kitty / 各种 bar）。
log "安装中文字体与基础字体（已装的会自动跳过）"
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

log "刷新字体缓存"
if command -v fc-cache >/dev/null 2>&1; then
    as_root fc-cache -f >/dev/null 2>&1 || true
    as_user fc-cache -f >/dev/null 2>&1 || true
fi
success "字体就绪"

# ------------------------------------------------------------------------------
# 5. TTY 控制台字体（图形界面之外黑框里的字体）
# ------------------------------------------------------------------------------
section "步骤 5/8" "TTY 控制台字体（terminus）"

if [ -f /etc/vconsole.conf ] && grep -q '^FONT=' /etc/vconsole.conf; then
    if grep -q '^FONT=ter-v28n' /etc/vconsole.conf; then
        success "/etc/vconsole.conf 的字体已经是 ter-v28n"
    else
        as_root sed -i 's|^FONT=.*|FONT=ter-v28n|' /etc/vconsole.conf
        success "/etc/vconsole.conf 的字体已改为 ter-v28n"
    fi
else
    printf 'FONT=ter-v28n\n' | as_root tee -a /etc/vconsole.conf >/dev/null
    success "/etc/vconsole.conf 写入 FONT=ter-v28n"
fi

# 只有在真实 TTY 里才能立刻 setfont；在图形终端里跑必然失败，忽略就好。
CUR_TTY="$(tty 2>/dev/null || true)"
case "$CUR_TTY" in
    /dev/tty[0-9]*)
        if as_root setfont ter-v28n 2>/dev/null; then
            success "当前控制台字体已切到 ter-v28n"
        else
            warn "setfont 失败，重启后由 /etc/vconsole.conf 接管"
        fi
        ;;
    *)
        log "当前不在 TTY 控制台（${CUR_TTY:-未知}），跳过即时生效，重启后自动生效"
        ;;
esac

log "让 systemd-vconsole-setup 重新读一遍配置"
as_root systemctl restart systemd-vconsole-setup >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 6. locale（目标机器是中文环境）
# ------------------------------------------------------------------------------
section "步骤 6/8" "locale（zh_CN.UTF-8 中文环境）"

NEED_GENERATE=0

# en_US.UTF-8 是不少构建脚本/容器的兜底，zh_CN.UTF-8 是日常用的，两个都要。
for _loc in en_US.UTF-8 zh_CN.UTF-8; do
    # locale -a 里显示成 zh_CN.utf8，所以只比对前半段
    if locale -a 2>/dev/null | grep -qi "${_loc/UTF-8/utf8}"; then
        success "$_loc 已经生成好了"
        continue
    fi

    log "$_loc 还没生成，先在 /etc/locale.gen 里启用它"
    # locale.gen 里的格式是 "zh_CN.UTF-8 UTF-8"，把行首的 # 去掉即可（已启用则无变化）
    as_root sed -i -E "s|^#[[:space:]]*(${_loc//./\\.}[[:space:]]+UTF-8)|\1|" /etc/locale.gen

    if grep -qE "^[[:space:]]*${_loc//./\\.}[[:space:]]+UTF-8" /etc/locale.gen; then
        success "$_loc 已在 /etc/locale.gen 中启用"
        NEED_GENERATE=1
    else
        warn "/etc/locale.gen 里找不到 $_loc 这一行，跳过（可能被手动改过）"
    fi
done

if [ "$NEED_GENERATE" -eq 1 ]; then
    log "生成 locale（可能要几十秒）"
    if as_root locale-gen; then
        success "locale 生成完成"
    else
        warn "locale-gen 失败，检查一下 /etc/locale.gen"
    fi
else
    success "locale 都是现成的，不用重新生成"
fi

# 默认语言：目标是中文环境。只有在 LANG 还没设或是 C/POSIX 时才写，
# 免得把别人特意设过的值（比如故意用英文界面）覆盖掉。
CUR_LANG="$(as_root sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | head -n 1 || true)"
if [ -z "${CUR_LANG:-}" ] || [ "$CUR_LANG" = "C" ] || [ "$CUR_LANG" = "POSIX" ]; then
    log "把 /etc/locale.conf 的 LANG 设为 zh_CN.UTF-8"
    if as_root grep -q '^LANG=' /etc/locale.conf 2>/dev/null; then
        as_root sed -i 's|^LANG=.*|LANG=zh_CN.UTF-8|' /etc/locale.conf
    else
        printf 'LANG=zh_CN.UTF-8\n' | as_root tee -a /etc/locale.conf >/dev/null
    fi
    success "默认语言 = zh_CN.UTF-8（重新登录后生效）"
else
    info_kv "默认语言" "$CUR_LANG" "保持不动，想改中文就改 /etc/locale.conf"
fi

# ------------------------------------------------------------------------------
# 7. archlinuxcn 社区源
# ------------------------------------------------------------------------------
section "步骤 7/8" "archlinuxcn 社区源"

# 为什么要它：yay / paru / archlinuxcn-keyring 这类包在里面是现成的，
# 比从 AUR 自举省事得多（00-utils 的 ensure_aur_helper 也会先看这些源）。
# 注意：这里用的是公共社区源，不是 shorin 的私有 [shorin-arch]。
# 镜像不写 USTC（以前在这台环境上超时）和 QLU（以前 404），
# 只留官方 CDN + 清华 / 华为 / HIT，官方源排第一。
if grep -q '^\[archlinuxcn\]' /etc/pacman.conf; then
    success "[archlinuxcn] 已经配置过了，不重复追加"
else
    log "追加 [archlinuxcn] 到 /etc/pacman.conf（先备份一份 pacman.conf）"
    as_root cp -a /etc/pacman.conf /etc/pacman.conf.chenpi.bak
    as_root tee -a /etc/pacman.conf >/dev/null <<'EOT'

[archlinuxcn]
Server = https://repo.archlinuxcn.org/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://repo.huaweicloud.com/archlinuxcn/$arch
Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
EOT
    success "[archlinuxcn] 已加入（原 pacman.conf 备份在 /etc/pacman.conf.chenpi.bak）"
fi

# 新加的源要先同步数据库，pacman 才认得里面的包（-Syu 顺便避免部分升级）
log "同步数据库"
if ! as_root pacman -Syu --noconfirm; then
    warn "同步 / 升级失败，archlinuxcn 的包可能暂时装不上"
fi

log "安装 archlinuxcn-keyring（不装的话 archlinuxcn 的包会卡在签名验证）"
pac_install archlinuxcn-keyring || true
if has_pkg archlinuxcn-keyring; then
    success "archlinuxcn-keyring 就绪"
else
    warn "archlinuxcn-keyring 没装上，archlinuxcn 的包可能因为签名失败装不了"
fi

# ------------------------------------------------------------------------------
# 8. AUR 助手
# ------------------------------------------------------------------------------
section "步骤 8/8" "AUR 助手"

# 不写 pacman -S yay paru：交给 ensure_aur_helper。
# 它会先看已配置的源（archlinuxcn 里就有 yay / paru），真没有才从 AUR 自举 yay-bin，
# 并且会处理"makepkg 不许用 root"这件事（root 跑时切回 TARGET_USER）。
ensure_aur_helper
if [ -n "${AUR_HELPER:-}" ]; then
    success "AUR 助手可用：$AUR_HELPER"
else
    warn "这次没弄到 AUR 助手，AUR 包会被后续模块跳过（装好后重跑会自动补上）"
fi

# ------------------------------------------------------------------------------
# 收尾
# ------------------------------------------------------------------------------
section "01a 完成" "基础系统配置汇总"
info_kv "编辑器" "${TARGET_EDITOR:-未设置}"
info_kv "locale" "en_US.UTF-8 + zh_CN.UTF-8"
info_kv "默认语言" "$(as_root sed -n 's/^LANG=//p' /etc/locale.conf 2>/dev/null | head -n 1 || true)"
info_kv "AUR 助手" "${AUR_HELPER:-无}"
info_kv "日志" "$LOG_FILE"
success "基础系统配置完成"
