#!/usr/bin/env bash
# ==============================================================================
# arch-install.sh — 在另一台 Arch 机器上恢复整套配置
#
# 用法：
#   ./arch-install.sh          正常跑（已完成的步骤自动跳过）
#   ./arch-install.sh --force  忽略进度记录，全部重跑
#   ./arch-install.sh --reset  只清空进度记录，不安装
#
# 设计参考 SHORiN-KiWATA/shorin-arch-setup（AGPL-3.0），保留了其中实用的几条：
# 断点续传 / tar 整包备份 / DM 冲突检测 / 安装期间临时免密 / 装后对账
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/dotfiles"
STATE_FILE="$SCRIPT_DIR/.install_progress"
SUDO_TEMP="/etc/sudoers.d/99_chenpi_install_temp"
STAMP="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------- 输出 ----------------------------------
C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
C_BLU=$'\033[0;34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
section() { printf "\n${C_BLU}==>${C_OFF} %s\n" "$*"; }
log()     { printf "    %s\n" "$*"; }
ok()      { printf "    ${C_GRN}✓${C_OFF} %s\n" "$*"; }
warn()    { printf "    ${C_YEL}!${C_OFF} %s\n" "$*"; }
err()     { printf "    ${C_RED}✗${C_OFF} %s\n" "$*" >&2; }

# ---------------------------------- 参数 ----------------------------------
for arg in "$@"; do
  case "$arg" in
    --reset) rm -f "$STATE_FILE"; printf "进度记录已清空，下次从头跑\n"; exit 0 ;;
    --force|-f) rm -f "$STATE_FILE"; printf "忽略进度记录，本次全部重跑\n" ;;
  esac
done

# ---------------------------------- 清单 ----------------------------------
if [ ! -f "$SCRIPT_DIR/apps.conf" ]; then
  err "找不到 apps.conf（配置清单）"
  exit 1
fi
source "$SCRIPT_DIR/apps.conf"

# -------------------------------- 环境检查 --------------------------------
section "环境检查"

if [ ! -d "$SRC" ]; then
  err "找不到 $SRC —— 先把仓库 clone 好再跑"
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  RUN_AS_ROOT=1
  TARGET_USER="${SUDO_USER:-}"
else
  RUN_AS_ROOT=0
  TARGET_USER="$(id -un)"
fi

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  err "别直接用 root 跑，配置会落到 /root 家目录"
  err "换成普通用户执行：./arch-install.sh（脚本自己会调 sudo）"
  exit 1
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  err "找不到 $TARGET_USER 的家目录"
  exit 1
fi

if ! command -v pacman >/dev/null 2>&1; then
  err "这不是 Arch（找不到 pacman）"
  exit 1
fi

ok "目标用户 $TARGET_USER（$TARGET_HOME）"
ok "配置仓库 $SCRIPT_DIR"
if [ "$RUN_AS_ROOT" -eq 1 ]; then
  warn "当前以 root 身份运行，恢复完会把属主改回 $TARGET_USER"
fi

touch "$STATE_FILE"

# -------------------------------- 辅助函数 --------------------------------
as_root() {
  if [ "$RUN_AS_ROOT" -eq 1 ]; then "$@"; else sudo "$@"; fi
}

fix_owner() {
  [ "$RUN_AS_ROOT" -eq 1 ] || return 0
  local p
  for p in "$@"; do
    if [ -e "$p" ]; then
      chown -R "$TARGET_USER:" "$p" 2>/dev/null || true
    fi
  done
}

is_done() { grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { printf '%s\n' "$1" >> "$STATE_FILE"; }

# 已完成的步骤直接跳过（返回 0 = 这次要跑）
begin_step() {
  if is_done "$1"; then
    printf "    ${C_GRN}✔${C_OFF} %s ${C_DIM}（已完成，跳过）${C_OFF}\n" "$1"
    return 1
  fi
  return 0
}

# ------------------------------ 临时免密 ------------------------------
NOPASSWD_ACTIVE=0

setup_nopasswd() {
  [ "$RUN_AS_ROOT" -eq 1 ] && return 0
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" | sudo tee "$SUDO_TEMP" >/dev/null
  # 先校验再启用，写坏了会让 sudo 整个失灵
  if ! sudo visudo -cf "$SUDO_TEMP" >/dev/null 2>&1; then
    sudo rm -f "$SUDO_TEMP"
    warn "免密规则没通过 visudo 校验，已删除，后面会多问几次密码"
    return 0
  fi
  sudo chmod 440 "$SUDO_TEMP"
  NOPASSWD_ACTIVE=1
  ok "安装期间免密（退出时自动删掉 $SUDO_TEMP）"
}

cleanup() {
  if [ "$NOPASSWD_ACTIVE" -eq 1 ] && [ -f "$SUDO_TEMP" ]; then
    sudo -n rm -f "$SUDO_TEMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ------------------------------ 步骤：备份 ------------------------------
do_backup() {
  local items=() etc_items=() i

  for i in .config .vim .icons .themes "$WALLPAPER_DIR" \
           .bashrc .bash_profile .bash_logout .fbtermrc \
           .vimrc .gtkrc-2.0 .gitconfig .wget-hsts; do
    if [ -e "$TARGET_HOME/$i" ]; then items+=("$i"); fi
  done

  if [ ${#items[@]} -eq 0 ]; then
    log "本机没有可备份的配置（像是全新的机器），跳过"
    return 0
  fi

  local tar_ex=()
  for i in "${BACKUP_EXCLUDES[@]}"; do tar_ex+=("--exclude=$i"); done

  BACKUP_HOME="$TARGET_HOME/dotfiles-backup-$STAMP.tar.gz"
  log "打包 ${#items[@]} 项 → $BACKUP_HOME"
  as_root tar -czf "$BACKUP_HOME" -C "$TARGET_HOME" "${tar_ex[@]}" "${items[@]}"
  fix_owner "$BACKUP_HOME"
  ok "家目录备份完成（$(du -h "$BACKUP_HOME" 2>/dev/null | cut -f1)）"

  for i in "${ETC_FILES[@]}"; do
    if [ -f "$i" ]; then etc_items+=("${i#/etc/}"); fi
  done
  if [ ${#etc_items[@]} -gt 0 ]; then
    BACKUP_ETC="$TARGET_HOME/dotfiles-backup-$STAMP-etc.tar.gz"
    as_root tar -czf "$BACKUP_ETC" -C /etc "${etc_items[@]}"
    fix_owner "$BACKUP_ETC"
    ok "系统配置备份完成（${#etc_items[@]} 个文件）"
  fi
}

# ------------------------------ 步骤：装包 ------------------------------
do_packages() {
  local pkg

  if [ -f "$SRC/pkglist.txt" ]; then
    local valid=() unknown=()
    # 先把官方源里不存在的挑出来，免得一颗坏包让整批 transaction 失败
    while read -r pkg; do
      if [ -n "$pkg" ]; then
        if pacman -Si "$pkg" >/dev/null 2>&1; then
          valid+=("$pkg")
        elif grep -qx "$pkg" "$SRC/pkglist-aur.txt" 2>/dev/null; then
          : # AUR 包，交给下面的 yay，不算异常
        else
          unknown+=("$pkg")
        fi
      fi
    done < "$SRC/pkglist.txt"

    if [ ${#unknown[@]} -gt 0 ]; then
      warn "官方源里找不到这 ${#unknown[@]} 个，先跳过：${unknown[*]}"
    fi
    if [ ${#valid[@]} -gt 0 ]; then
      if printf '%s\n' "${valid[@]}" | as_root pacman -S --needed --noconfirm -; then
        ok "官方源软件包 ✓（${#valid[@]} 个）"
      else
        # 整批挂了就逐个来，别让一个冲突包把后面的配置恢复也带崩
        warn "整批失败（多半有包互相冲突），改成逐个装"
        local failed=()
        for pkg in "${valid[@]}"; do
          as_root pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
        done
        if [ ${#failed[@]} -gt 0 ]; then
          warn "这些官方源包装不上（${#failed[@]} 个）：${failed[*]}"
        else
          ok "逐个装完成（${#valid[@]} 个）"
        fi
      fi
    fi
  else
    warn "没有 pkglist.txt，跳过官方源包"
  fi

  if [ ! -f "$SRC/pkglist-aur.txt" ]; then
    return 0
  fi

  if command -v yay >/dev/null 2>&1; then
    if yay -S --needed --noconfirm - < "$SRC/pkglist-aur.txt"; then
      ok "AUR 软件包 ✓"
    else
      warn "AUR 整批失败，改成逐个装（慢，但能看出是哪个包坏）"
      local failed=()
      while read -r pkg; do
        if [ -n "$pkg" ]; then
          yay -S --needed --noconfirm "$pkg" >/dev/null 2>&1 || failed+=("$pkg")
        fi
      done < "$SRC/pkglist-aur.txt"
      if [ ${#failed[@]} -gt 0 ]; then
        warn "这些 AUR 包装不上（${#failed[@]} 个）：${failed[*]}"
      fi
    fi
  else
    warn "没装 yay，跳过 AUR 包"
    warn "想装的话：git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si"
  fi
}

# ------------------------------ 步骤：恢复配置 ------------------------------
do_config() {
  local i n missing etc_n

  mkdir -p "$TARGET_HOME/.config"
  n=0
  missing=()
  for i in "${CONFIG_APPS[@]}"; do
    if [ -e "$SRC/.config/$i" ]; then
      rm -rf "${TARGET_HOME:?}/.config/$i"
      cp -r "$SRC/.config/$i" "$TARGET_HOME/.config/"
      n=$((n + 1))
    else
      missing+=("$i")
    fi
  done
  ok ".config 恢复 $n 项"
  if [ ${#missing[@]} -gt 0 ]; then
    warn "仓库里没有这 ${#missing[@]} 项，跳过：${missing[*]}"
  fi

  n=0
  for i in "${TOP_FILES[@]}"; do
    if [ -f "$SRC/$i" ]; then
      rm -f "${TARGET_HOME:?}/$i"
      cp -a "$SRC/$i" "$TARGET_HOME/"
      n=$((n + 1))
    fi
  done
  for i in "${TOP_DIRS[@]}"; do
    if [ -d "$SRC/$i" ]; then
      rm -rf "${TARGET_HOME:?}/$i"
      mkdir -p "$TARGET_HOME/$i"
      cp -a "$SRC/$i/." "$TARGET_HOME/$i/"
      n=$((n + 1))
    fi
  done
  ok "顶层 dotfile 和目录恢复 $n 项"

  if [ -d "$SRC/$WALLPAPER_DIR" ]; then
    mkdir -p "$TARGET_HOME/$(dirname "$WALLPAPER_DIR")"
    rm -rf "${TARGET_HOME:?}/$WALLPAPER_DIR"
    cp -a "$SRC/$WALLPAPER_DIR" "$TARGET_HOME/$(dirname "$WALLPAPER_DIR")/"
    ok "壁纸恢复（$(find "$TARGET_HOME/$WALLPAPER_DIR" -type f | wc -l) 个文件）"
  fi

  etc_n=0
  for i in "${ETC_FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/etc/${i#/etc/}" ]; then
      as_root mkdir -p "$(dirname "$i")"
      as_root cp -a "$SCRIPT_DIR/etc/${i#/etc/}" "$i"
      etc_n=$((etc_n + 1))
    fi
  done
  ok "系统级配置（/etc）恢复 $etc_n 个文件"

  # root 跑的话把属主改回去
  if [ "$RUN_AS_ROOT" -eq 1 ]; then
    fix_owner "$TARGET_HOME/.config" "$TARGET_HOME/$WALLPAPER_DIR"
    for i in "${TOP_FILES[@]}" "${TOP_DIRS[@]}"; do
      fix_owner "$TARGET_HOME/$i"
    done
  fi
}

# ------------------------------ 步骤：DM 检查 ------------------------------
do_dm_check() {
  local dm found=() enabled=""

  for dm in "${KNOWN_DMS[@]}"; do
    if pacman -Qq "$dm" >/dev/null 2>&1; then found+=("$dm"); fi
  done

  if [ ${#found[@]} -eq 0 ]; then
    warn "没装任何显示管理器 —— niri 得从 TTY 手动起（或者装 ly / sddm 再登录）"
  elif [ ${#found[@]} -eq 1 ]; then
    ok "检测到显示管理器：${found[0]}"
  else
    warn "检测到多个显示管理器：${found[*]}"
  fi

  for dm in "${found[@]}"; do
    if systemctl is-enabled "$dm" >/dev/null 2>&1; then enabled="${enabled:+$enabled }$dm"; fi
  done

  if [ -n "$enabled" ]; then
    ok "已启用的：$enabled"
  elif [ ${#found[@]} -gt 0 ]; then
    warn "一个都没启用，登录界面可能起不来"
    warn "要哪个就 sudo systemctl enable <名字>"
  fi

  if [ ${#found[@]} -gt 1 ]; then
    warn "同时启用多个会互相抢显示权限，确认只留一个"
  fi
}

# ------------------------------ 步骤：装后对账 ------------------------------
do_verify() {
  local pkg list total=0 missing=()

  for list in "$SRC/pkglist.txt" "$SRC/pkglist-aur.txt"; do
    if [ -f "$list" ]; then
      while read -r pkg; do
        if [ -n "$pkg" ]; then
          total=$((total + 1))
          pacman -Qq "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
        fi
      done < "$list"
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    ok "对账通过：$total 个包都在"
    return 0
  fi

  warn "对账：$total 个包里缺 ${#missing[@]} 个"
  printf '      %s\n' "${missing[@]}"
  return 1
}

# ================================== 主流程 ==================================

if begin_step "临时免密"; then
  setup_nopasswd
  mark_done "临时免密"
fi

if begin_step "备份现有配置"; then
  section "备份现有配置"
  do_backup
  mark_done "备份现有配置"
fi

if begin_step "安装软件包"; then
  section "安装软件包"
  do_packages
  mark_done "安装软件包"
fi

if begin_step "恢复配置"; then
  section "恢复配置"
  do_config
  mark_done "恢复配置"
fi

if begin_step "显示管理器检查"; then
  section "显示管理器检查"
  do_dm_check
  mark_done "显示管理器检查"
fi

section "装后对账"
verify_failed=0
do_verify || verify_failed=1

section "完成"
if [ -n "${BACKUP_HOME:-}" ]; then log "家目录备份：$BACKUP_HOME"; fi
if [ -n "${BACKUP_ETC:-}" ]; then log "系统配置备份：$BACKUP_ETC"; fi
log "重跑会自动跳过已完成的步骤；要全部重来加 --force"
log "niri 会话从登录界面选，壁纸在 ~/$WALLPAPER_DIR"

if [ "$verify_failed" -eq 1 ]; then
  err "有包没装上，照上面的清单补一下再重跑对账"
  exit 1
fi
ok "全部完成"
