#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# ==============================================================================
# 00-btrfs-init.sh — Btrfs 快照安全网（root + home）
#
# 骨架改写自 SHORiN-KiWATA/shorin-arch-setup 的 scripts/00-btrfs-init.sh（AGPL-3.0）
#
# 装 snapper、给 / 和 /home 建快照配置、接上 grub-btrfs，然后打出「装系统之前」
# 的还原点。后面任何一步翻车都能退回来，所以必须排在所有装包动作之前。
#
# 与参考版不同：不强制 root（要动系统的地方用 as_root）、装包走 pac_install、
# 不部署他的私有脚本、不创建用户（TARGET_USER / TARGET_HOME 由主控 export）。
# GRUB 目录定位在本文件里就地展开 —— 公共库的约定是不重复造函数。
# ==============================================================================

require_arch

# 本次运行共用一个时间戳：所有 .bak 备份都带它，方便按时间点整体回退
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"

# 还原点的描述文本（幂等标记）。重复运行时靠这两个字符串判断「这个还原点是不是
# 已经打过了」，所以改字串等于换标记，会再多打一个快照。
SNAP_ROOT_DESC="chenpi-setup-前"
SNAP_HOME_DESC="chenpi-setup-前"

# snapper 调参。ALLOW_GROUPS=wheel 让 btrfs-assistant 这类 GUI 能读快照；
# TIMELINE_LIMIT_HOURLY=3 / NUMBER_LIMIT=10 防止快照把盘塞满。
# 嫌 home 时间线快照占地方就把 TIMELINE_CREATE 改 no —— root 和 home 共用这份。
SNAP_SETTINGS=(
    "ALLOW_GROUPS=wheel"
    "TIMELINE_CREATE=yes"
    "TIMELINE_CLEANUP=yes"
    "NUMBER_MIN_AGE=0"
    "NUMBER_LIMIT=10"
    "NUMBER_LIMIT_IMPORTANT=5"
    "TIMELINE_LIMIT_HOURLY=3"
    "TIMELINE_LIMIT_DAILY=0"
    "TIMELINE_LIMIT_WEEKLY=0"
    "TIMELINE_LIMIT_MONTHLY=0"
    "TIMELINE_LIMIT_YEARLY=0"
)

# 状态位：GRUB 那段能不能动（0 = 布局不对，别乱写）
GRUB_OK=1
# 状态位：root 还原点有没有打上（0 = 没打上，最后要报错退出）
ROOT_SNAP_OK=1

section "$(t "阶段 0" "Stage 0")" "$(t "Btrfs 快照安全网" "btrfs snapshot safety net")"
info_kv "$(t "配置仓库" "repo")" "$REPO_ROOT"
# 【注意】本模块不碰家目录，TARGET_USER / TARGET_HOME 只是打出来对着日志看。
# 用 ${X:-} 是因为脚本开了 set -u：单独跑本模块时读到空变量直接就崩了。
info_kv "$(t "目标用户" "target user")" "${TARGET_USER:-$(t "未设置" "unset")}" "${TARGET_HOME:-}"

# ------------------------------------------------------------------------------
# 0. 环境判断：根分区不是 btrfs 就整套跳过
# ------------------------------------------------------------------------------
# 快照依赖 btrfs 的 CoW，ext4 没有等价物。这是「不适用」不是「失败」：直接返回，后面照常跑。
ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
if [ "$ROOT_FSTYPE" != "btrfs" ]; then
    warn "$(t "根分区不是 Btrfs（${ROOT_FSTYPE:-未知}），快照安全网整套跳过" "root fs is ${ROOT_FSTYPE:-unknown}, not btrfs — snapshots skipped")"
    log "$(t "非 Btrfs 没有 CoW 快照，后面的模块不受影响" "no CoW snapshots without btrfs; later modules are unaffected")"
    exit 0
fi
success "$(t "根分区是 Btrfs，继续配置快照安全网" "root fs is btrfs — configuring snapshots")"

# ------------------------------------------------------------------------------
# 1. 定位 GRUB 目录：/boot/grub 有可能根本不存在
# ------------------------------------------------------------------------------
# 【为什么必须处理】archinstall 在「没有独立 /boot 分区 + ESP 挂在 /boot 以外」
# 时会给 grub-install 传 --boot-directory=$ESP，于是模块/grub.cfg/grubenv 全落在
# $ESP/grub，而 /boot/grub 不存在 —— 可 grub-mkconfig / grub-editenv /
# grub-btrfs 都把 /boot/grub 写死，不处理就会把配置写进「没人读的地方」，
# 看着成功其实无效。
#
# 只做加法，绝不删改既有东西：
#   - 只在 /boot/grub 完全不存在时补软链，而且必须链目录：这些工具都是
#     「写 .tmp 再 rename」，文件级软链会被 rename 直接替换掉，链一次坏一次
#   - 判据用模块目录（*/normal.mod）而不是 grub.cfg：后者谁都能生成，会误判
#   - /boot/grub 在标准布局下本来就存在，那就什么都不做
section "$(t "安全网" "Safety net")" "$(t "定位 GRUB 目录" "locate GRUB dir")"

if command -v grub-mkconfig >/dev/null 2>&1; then
    # 在已挂载的 vfat（ESP）分区里找真正的 GRUB 目录
    ESP_GRUB=""
    while read -r _mp; do
        [ -n "$_mp" ] || continue
        if compgen -G "$_mp/grub/*/normal.mod" >/dev/null 2>&1; then
            ESP_GRUB="$_mp/grub"
            break
        fi
    done < <(findmnt -n -l -o TARGET -t vfat 2>/dev/null)

    if [ -z "$ESP_GRUB" ]; then
        log "$(t "GRUB 不在 ESP 里，按标准布局处理（/boot/grub）" "GRUB not in ESP — assuming standard layout (/boot/grub)")"
    elif [ -e "/boot/grub" ] || [ -L "/boot/grub" ]; then
        # 已存在（真目录 / 软链 / 悬空软链）→ 一律不碰
        if [ -d "/boot/grub" ] && [ ! -L "/boot/grub" ] \
           && ! compgen -G "/boot/grub/*/normal.mod" >/dev/null 2>&1; then
            # 唯一的例外：它是个没有模块的空壳目录，说明布局其实是错的。
            # 修它要删既有目录，超出本模块职责而且风险高，只提醒人工处理。
            warn "$(t "GRUB 实际装在 $ESP_GRUB，但 /boot/grub 是没有模块的空目录" "GRUB is really in $ESP_GRUB; /boot/grub is an empty shell")"
            warn "$(t "这种布局下改 GRUB 配置不生效，需要人工处理：" "GRUB changes won't take effect here — fix it manually:")"
            warn "  rm -rf /boot/grub && ln -sfn $ESP_GRUB /boot/grub"
            GRUB_OK=0
        else
            log "$(t "/boot/grub 已存在（真目录或软链），不碰" "/boot/grub exists — leaving it alone")"
        fi
    else
        log "$(t "GRUB 装在 ESP 里，/boot/grub 不存在，补一个软链" "GRUB lives in the ESP — creating a /boot/grub symlink")"
        log "$(t "链上之后 grub-mkconfig / grub-editenv / grub-btrfs 才会写到真正被读的位置" "so grub-mkconfig / grub-editenv / grub-btrfs write where GRUB reads")"
        if as_root ln -sfn "$ESP_GRUB" "/boot/grub"; then
            success "$(t "已建立软链：/boot/grub -> $ESP_GRUB" "symlink created: /boot/grub -> $ESP_GRUB")"
        else
            warn "$(t "软链没建成，后面的 GRUB 配置会写到没被读取的位置" "symlink failed — later GRUB writes would go to the wrong place")"
            GRUB_OK=0
        fi
    fi
else
    log "$(t "没装 grub-mkconfig，跳过 GRUB 目录处理（systemd-boot / limine 属正常）" "no grub-mkconfig — GRUB dir step skipped (normal for systemd-boot/limine)")"
fi

# ------------------------------------------------------------------------------
# 2. 装 snapper
# ------------------------------------------------------------------------------
# 只装本体；GUI（btrfs-assistant）交给用户自己决定，这里只在最后提示一句。
section "$(t "第 1 步" "Step 1")" "$(t "安装 snapper" "install snapper")"

if has_pkg snapper; then
    success "$(t "snapper 已经装过了，跳过" "snapper already installed")"
else
    log "$(t "装 snapper" "installing snapper")"
    pac_install snapper || true
    if has_pkg snapper; then
        success "$(t "snapper 装好了" "snapper installed")"
    else
        error "$(t "snapper 装不上，快照安全网没法继续" "cannot install snapper — aborting")"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 3. root（/）快照配置
# ------------------------------------------------------------------------------
# 幂等判据：list-configs 里已有 root 就直接跳过，绝不动用户调过的参数
section "$(t "第 2 步" "Step 2")" "$(t "配置 root 快照" "configure root snapshots")"

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    success "$(t "root 配置已存在，跳过（不动你现有的参数）" "root config exists — skipping (keeps your settings)")"
else
    # 【为什么】创建配置前必须清掉已存在的 /.snapshots：snapper 要求自己建这个
    # 子卷，占着位置就创建失败。挂载点 / 已存在的 btrfs 子卷（根 inode 固定 256）
    # 都保留，只有普通目录会被挪走 —— 而且用 mv 不用 rm：挪走还能搬回来，删掉就没了。
    if [ -e "/.snapshots" ] || [ -L "/.snapshots" ]; then
        if [ "$(findmnt -n -o TARGET -T /.snapshots 2>/dev/null || true)" = "/.snapshots" ]; then
            log "$(t "/.snapshots 是挂载点，保留不动" "/.snapshots is a mountpoint — keeping it")"
        elif [ "$(stat -c %i /.snapshots 2>/dev/null || echo 0)" = "256" ]; then
            log "$(t "/.snapshots 是 btrfs 子卷，保留不动" "/.snapshots is a btrfs subvolume — keeping it")"
        else
            log "$(t "/.snapshots 是个普通目录，snapper 建不了子卷，先改名挪到一边" "/.snapshots is a plain dir — moving it aside")"
            if as_root mv "/.snapshots" "/.snapshots.bak-${BACKUP_TS}"; then
                warn "$(t "原 /.snapshots 已挪到 /.snapshots.bak-${BACKUP_TS}，确认没用可以自己删" "old /.snapshots moved to /.snapshots.bak-${BACKUP_TS}")"
            else
                warn "$(t "挪走 /.snapshots 失败，snapper 多半建不了配置" "could not move /.snapshots — snapper will likely fail")"
            fi
        fi
    fi

    log "$(t "创建 root 快照配置（新建 .snapshots 子卷 + 追加 fstab 项）" "creating root config (new .snapshots subvol + fstab entry)")"
    if exe as_root snapper -c root create-config /; then
        success "$(t "root 配置创建好了" "root config created")"
    else
        warn "$(t "root 配置创建失败，后面打还原点会跳过" "root config failed — snapshot step will be skipped")"
    fi
fi

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    # set-config 是 snapper 的官方接口且幂等。
    # 【为什么不备份 /etc/snapper/configs/root 再手改】那目录里每个文件都会被
    # snapper 当成一份配置，塞 .bak 进去会多出一份名字乱七八糟的「配置」。
    log "$(t "写入推荐参数（时间线快照 + 自动清理 + wheel 组可读）" "applying recommended settings")"
    exe as_root snapper -c root set-config "${SNAP_SETTINGS[@]}" || warn "$(t "参数没写全，但配置本身可用" "some settings rejected; config still usable")"

    log "$(t "启用两个 timer：时间线快照 + 自动清理（重复跑安全）" "enabling timeline and cleanup timers (idempotent)")"
    exe as_root systemctl enable --now snapper-timeline.timer snapper-cleanup.timer \
        || warn "$(t "timer 没启用，自动快照/清理不会跑（手动快照不受影响）" "timers not enabled — auto snapshot/cleanup won't run")"
    success "$(t "root 快照配置就绪" "root snapshot config ready")"
else
    ROOT_SNAP_OK=0
fi

# ------------------------------------------------------------------------------
# 4. home（/home）快照配置
# ------------------------------------------------------------------------------
# 只在 /home 是独立 btrfs 时做：家目录里才是真正在意的数据
section "$(t "第 3 步" "Step 3")" "$(t "配置 home 快照" "configure home snapshots")"

HOME_FSTYPE="$(findmnt -n -o FSTYPE /home 2>/dev/null || true)"
if [ "$HOME_FSTYPE" != "btrfs" ]; then
    warn "$(t "/home 不是 btrfs（${HOME_FSTYPE:-未知}），跳过 home 快照" "/home is ${HOME_FSTYPE:-unknown}, not btrfs — skipping")"
    log "$(t "这种情况多半是 /home 就在 root 子卷里，root 快照已经覆盖它" "/home is probably inside the root subvolume — covered by root snapshots")"
else
    if as_root snapper list-configs 2>/dev/null | grep -q '^home '; then
        success "$(t "home 配置已存在，跳过创建" "home config exists — skipping")"
    else
        if [ -e "/home/.snapshots" ] || [ -L "/home/.snapshots" ]; then
            if [ "$(findmnt -n -o TARGET -T /home/.snapshots 2>/dev/null || true)" = "/home/.snapshots" ]; then
                log "$(t "/home/.snapshots 是挂载点，保留不动" "/home/.snapshots is a mountpoint — keeping it")"
            elif [ "$(stat -c %i /home/.snapshots 2>/dev/null || echo 0)" = "256" ]; then
                log "$(t "/home/.snapshots 是 btrfs 子卷，保留不动" "/home/.snapshots is a btrfs subvolume — keeping it")"
            else
                log "$(t "/home/.snapshots 是个普通目录，先改名挪到一边" "/home/.snapshots is a plain dir — moving it aside")"
                if as_root mv "/home/.snapshots" "/home/.snapshots.bak-${BACKUP_TS}"; then
                    warn "$(t "原 /home/.snapshots 已挪到 /home/.snapshots.bak-${BACKUP_TS}" "old /home/.snapshots moved to /home/.snapshots.bak-${BACKUP_TS}")"
                else
                    warn "$(t "挪走 /home/.snapshots 失败，home 配置多半建不起来" "could not move /home/.snapshots — home config will likely fail")"
                fi
            fi
        fi

        log "$(t "创建 home 快照配置（新建 .snapshots 子卷）" "creating home config (new .snapshots subvol)")"
        if exe as_root snapper -c home create-config /home; then
            success "$(t "home 配置创建好了" "home config created")"
            exe as_root snapper -c home set-config "${SNAP_SETTINGS[@]}" || warn "$(t "参数没写全，但配置本身可用" "some settings rejected; config still usable")"
        else
            # /home 不是 btrfs 子卷时 snapper 会拒绝，这里只警告不中断
            warn "$(t "home 配置创建失败（/home 不是独立子卷时会这样），root 快照不受影响" "home config failed (/home not a subvolume) — root snapshots unaffected")"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. GRUB：记住上次启动项 + 把快照子菜单集成进菜单
# ------------------------------------------------------------------------------
# 分三小块，每块都先判断「是不是已经做过」：
#   5a savedefault（回滚后记住启动项）· 5b grub-btrfs（快照子菜单）· 5c grubenv 环境块
section "$(t "安全网" "Safety net")" "$(t "GRUB 启动项记忆与快照菜单" "GRUB savedefault + snapshot menu")"

if [ "$GRUB_OK" -eq 1 ] && [ -f "/etc/default/grub" ] && command -v grub-mkconfig >/dev/null 2>&1; then
    # NEED_REGEN：这次是不是有必要重新生成 grub.cfg（改过配置、或新装了 grub-btrfs）
    NEED_REGEN=0

    # ---- 5a. UKI（统一内核镜像）由 kernel-install 自己管条目，
    #          GRUB_DEFAULT=saved 那套记忆在 UKI 下没意义还可能打架，跳过 ----
    UKI_ENABLED=0
    if grep -qsE '^[[:space:]]*[[:alnum:]_]+_uki[[:space:]]*=' /etc/mkinitcpio.d/*.preset 2>/dev/null \
       || grep -qsE '^[[:space:]]*layout[[:space:]]*=[[:space:]]*uki([[:space:]]|$)' /etc/kernel/install.conf 2>/dev/null; then
        UKI_ENABLED=1
    fi

    if [ "$UKI_ENABLED" -eq 1 ]; then
        log "$(t "检测到 UKI 布局，跳过 GRUB_DEFAULT=saved（UKI 下这套记忆机制不适用）" "UKI layout detected — skipping GRUB_DEFAULT=saved")"
    elif grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub \
      && grep -qE '^GRUB_SAVEDEFAULT=(true|"true")' /etc/default/grub; then
        success "$(t "GRUB 的 savedefault 已经配好了，跳过" "GRUB savedefault already configured — skipping")"
    else
        log "$(t "改 /etc/default/grub：GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true" "editing /etc/default/grub: GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true")"
        # 【为什么】回滚快照后 GRUB 要能记住「上次从哪个项启动」，否则每次都跳回默认项。
        # 改系统配置文件前先留一份原样备份。
        if as_root cp -a /etc/default/grub "/etc/default/grub.bak-${BACKUP_TS}"; then
            success "$(t "原文件已备份：/etc/default/grub.bak-${BACKUP_TS}" "backed up to /etc/default/grub.bak-${BACKUP_TS}")"
        else
            warn "$(t "备份 /etc/default/grub 失败！先手动复制一份再重跑" "backup of /etc/default/grub failed — copy it manually and rerun")"
            error "$(t "拒绝在没有备份的情况下改引导配置" "refusing to touch the boot config without a backup")"
            exit 1
        fi

        # 写失败不在这里中断，写完后统一校验，校验不过就用备份回滚 ——
        # 半改半不改的 grub 配置比不改更危险。
        if grep -qE '^GRUB_DEFAULT=' /etc/default/grub; then
            as_root sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub || true
        else
            # 只有被注释掉的 GRUB_DEFAULT 时不硬塞 sed，直接追加一行
            as_root sh -c "printf 'GRUB_DEFAULT=saved\n' >> /etc/default/grub" || true
        fi

        if grep -qE '^#*GRUB_SAVEDEFAULT=' /etc/default/grub; then
            as_root sed -i 's/^#*GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub || true
        else
            as_root sh -c "printf 'GRUB_SAVEDEFAULT=true\n' >> /etc/default/grub" || true
        fi

        if grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub \
           && grep -qE '^GRUB_SAVEDEFAULT=(true|"true")' /etc/default/grub; then
            NEED_REGEN=1
            success "$(t "已写入 GRUB_DEFAULT=saved / GRUB_SAVEDEFAULT=true" "wrote GRUB_DEFAULT=saved / GRUB_SAVEDEFAULT=true")"
        else
            warn "$(t "写入没生效（可能权限或磁盘有问题），用备份恢复原样" "write did not take effect — restoring from backup")"
            as_root cp -a "/etc/default/grub.bak-${BACKUP_TS}" /etc/default/grub || true
            error "$(t "/etc/default/grub 改不动，这一步跳过；原文件已还原" "cannot modify /etc/default/grub — step skipped; original restored")"
        fi
    fi

    # ---- 5b. grub-btrfs：GRUB 菜单里的快照子菜单 ----
    # 装了它 + 启用 grub-btrfsd，快照一变就自动刷新 grub.cfg。
    if has_pkg grub-btrfs; then
        log "$(t "grub-btrfs 已经装过了，跳过" "grub-btrfs already installed — skipping")"
    else
        log "$(t "装 grub-btrfs（快照子菜单）+ inotify-tools（grub-btrfsd 的依赖），都在官方源" "installing grub-btrfs + inotify-tools from the official repos")"
        pac_install grub-btrfs inotify-tools || true
        if has_pkg grub-btrfs; then
            success "$(t "grub-btrfs 装好了" "grub-btrfs installed")"
            NEED_REGEN=1
        else
            warn "$(t "grub-btrfs 没装上，菜单里不会有快照子菜单（快照本身照常工作）" "grub-btrfs missing — no snapshot submenu (snapshots still work)")"
            warn "$(t "源修好之后重跑本模块即可" "fix the mirrors and rerun this module")"
        fi
    fi

    if has_pkg grub-btrfs; then
        log "$(t "启用 grub-btrfsd（快照一变就刷新 GRUB 菜单）" "enabling grub-btrfsd (refreshes the menu on snapshot change)")"
        exe as_root systemctl enable --now grub-btrfsd.service \
            || warn "$(t "grub-btrfsd 没起来，快照子菜单要手动 grub-mkconfig 才刷新" "grub-btrfsd not started — submenu needs a manual grub-mkconfig")"
    fi

    # ---- 5b-2. 重新生成前先看一眼 Windows 双系统条目会不会丢 ----
    # 只提醒，不擅自改 os-prober 开关（那是 02c 的活）。
    if ! command -v os-prober >/dev/null 2>&1; then
        warn "$(t "没装 os-prober，重新生成菜单后可能看不到 Windows 启动项" "no os-prober — the Windows entry may vanish after regenerating")"
        warn "$(t "02c-dualboot-fix 模块会专门修这个" "02c-dualboot-fix will fix this")"
    elif grep -qE '^GRUB_DISABLE_OS_PROBER=(true|"true")' /etc/default/grub; then
        warn "$(t "GRUB_DISABLE_OS_PROBER=true，重新生成菜单后 Windows 项不会出现" "GRUB_DISABLE_OS_PROBER=true — the Windows entry won't appear")"
        warn "$(t "同样交给 02c-dualboot-fix 处理" "left to 02c-dualboot-fix as well")"
    fi

    # ---- 5b-3. 真正重新生成 grub.cfg ----
    # 只有「改过东西」才重生成：反复生成没意义，而且动引导的改坏风险不为零。
    if [ "$NEED_REGEN" -eq 1 ]; then
        GRUB_CFG_BACKUP_OK=1
        if [ -f "/boot/grub/grub.cfg" ]; then
            if as_root cp -a /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak-${BACKUP_TS}"; then
                success "$(t "旧菜单已备份：/boot/grub/grub.cfg.bak-${BACKUP_TS}" "old menu backed up to /boot/grub/grub.cfg.bak-${BACKUP_TS}")"
            else
                # 备份失败说明 /boot 只读或满了；此时重生成有可能写坏 grub.cfg
                # 导致开不了机，宁可不做。
                warn "$(t "旧菜单备份失败（/boot 只读或空间不足），这次不重新生成菜单更稳妥" "menu backup failed (/boot read-only or full) — skipping regeneration")"
                GRUB_CFG_BACKUP_OK=0
            fi
        else
            log "$(t "还没有 /boot/grub/grub.cfg（首次生成），不需要备份" "no grub.cfg yet (first generation) — nothing to back up")"
        fi
        if [ "$GRUB_CFG_BACKUP_OK" -eq 1 ]; then
            log "$(t "重新生成 GRUB 菜单（会覆盖 grub.cfg，上面已先备份）" "regenerating the GRUB menu (overwrites grub.cfg, backed up above)")"
            # LANG 固定成英文，避免 grub-mkconfig 吐中文把菜单项搞乱
            exe as_root env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg \
                || warn "$(t "grub-mkconfig 失败，用 grub.cfg.bak-${BACKUP_TS} 顶回去再排查" "grub-mkconfig failed — restore grub.cfg.bak-${BACKUP_TS} and investigate")"
        else
            log "$(t "跳过生成菜单；修好 /boot 之后重跑本模块" "menu generation skipped — fix /boot and rerun this module")"
        fi
    else
        log "$(t "GRUB 配置这次没改动，跳过重新生成菜单" "GRUB config unchanged — skipping menu regeneration")"
    fi

    # ---- 5c. Btrfs 上的 grubenv 环境块 ----
    # GRUB 能就地改 FAT/ext，但 btrfs 不支持局部改写，所以要先写一次让 grubenv
    # 预留出环境块（env_block=），savedefault 才存得住；/boot/grub 不在 btrfs 上
    # （ESP 直接挂 /boot 的常见布局）时 GRUB 本来就能直接写，判断后说明并跳过。
    GRUB_DIR_FSTYPE="$(findmnt -n -o FSTYPE -T /boot/grub 2>/dev/null || true)"
    if [ "$GRUB_DIR_FSTYPE" = "btrfs" ] && [ "$UKI_ENABLED" -eq 0 ] \
       && command -v grub-editenv >/dev/null 2>&1; then
        if as_root grub-editenv - list 2>/dev/null | grep -q '^env_block='; then
            success "$(t "grubenv 里已经预留过环境块，跳过" "grubenv already has an env block — skipping")"
        else
            log "$(t "grubenv 在 btrfs 上，先写一次把环境块预留出来" "grubenv is on btrfs — writing once to reserve the env block")"
            exe as_root grub-editenv - set ok=1 || warn "$(t "grub-editenv 写入失败" "grub-editenv write failed")"
            if as_root grub-editenv - list 2>/dev/null | grep -q '^env_block='; then
                success "$(t "环境块预留成功，savedefault 可以正常落盘" "env block reserved — savedefault can persist")"
            else
                warn "$(t "还是没看到 env_block，savedefault 可能存不住（不影响正常启动）" "still no env_block — savedefault may not persist (booting is fine)")"
            fi
        fi
    elif [ -n "$GRUB_DIR_FSTYPE" ] && [ "$GRUB_DIR_FSTYPE" != "btrfs" ]; then
        log "$(t "/boot/grub 在 $GRUB_DIR_FSTYPE 上（不是 btrfs），GRUB 能直接写，无需预留环境块" "/boot/grub is on $GRUB_DIR_FSTYPE — GRUB can write directly, no reservation needed")"
    fi
else
    if [ "$GRUB_OK" -eq 0 ]; then
        warn "$(t "GRUB 目录布局异常（见上面的提醒），GRUB 相关配置全部跳过，等人工修好再重跑" "broken GRUB dir layout — all GRUB steps skipped, fix it and rerun")"
    else
        warn "$(t "没有 /etc/default/grub 或 grub-mkconfig，跳过 GRUB 相关配置" "no /etc/default/grub or grub-mkconfig — GRUB steps skipped")"
        log "$(t "如果这台机器用的是 systemd-boot / limine，那属于正常情况" "that is normal if this machine uses systemd-boot / limine")"
    fi
fi

# ------------------------------------------------------------------------------
# 6. 打第一个还原点（装系统之前的干净状态）
# ------------------------------------------------------------------------------
# 这是本模块的核心产出：后面任何一步（装包、换配置、恢复 dotfiles）翻车都能
# 回到这个点。幂等判据是「有没有同名的快照描述」，避免重跑一次多一个快照。
section "$(t "第 4 步" "Step 4")" "$(t "打「装系统之前」的还原点" "snapshot before install")"

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    if as_root snapper -c root list --columns description 2>/dev/null | grep -Fqx "$SNAP_ROOT_DESC"; then
        success "$(t "root 上已经有还原点「$SNAP_ROOT_DESC」，跳过" "root already has snapshot \"$SNAP_ROOT_DESC\" — skipping")"
    else
        log "$(t "在 root 上打还原点：「$SNAP_ROOT_DESC」" "creating root snapshot \"$SNAP_ROOT_DESC\"")"
        if exe as_root snapper -c root create --type single --description "$SNAP_ROOT_DESC"; then
            success "$(t "root 还原点打好了，出问题可以退回来" "root snapshot created — you can roll back to it")"
        else
            warn "$(t "root 还原点没打上" "root snapshot failed")"
            ROOT_SNAP_OK=0
        fi
    fi
else
    warn "$(t "没有 root 的 snapper 配置，跳过还原点" "no root snapper config — skipping the snapshot")"
    ROOT_SNAP_OK=0
fi

if as_root snapper list-configs 2>/dev/null | grep -q '^home '; then
    if as_root snapper -c home list --columns description 2>/dev/null | grep -Fqx "$SNAP_HOME_DESC"; then
        success "$(t "home 上已经有还原点「$SNAP_HOME_DESC」，跳过" "home already has snapshot \"$SNAP_HOME_DESC\" — skipping")"
    else
        log "$(t "在 home 上打还原点：「$SNAP_HOME_DESC」" "creating home snapshot \"$SNAP_HOME_DESC\"")"
        if exe as_root snapper -c home create --type single --description "$SNAP_HOME_DESC"; then
            success "$(t "home 还原点打好了" "home snapshot created")"
        else
            # home 快照失败不致命（root 有就行），只警告
            warn "$(t "home 还原点没打上，不影响后续步骤" "home snapshot failed — non-fatal")"
        fi
    fi
else
    log "$(t "没有 home 的 snapper 配置，跳过 home 还原点" "no home snapper config — skipping")"
fi

# 本模块不往家目录写文件，用不到 as_user（家目录在 04-restore-config 才动）

# ------------------------------------------------------------------------------
# 7. 收尾：怎么回滚
# ------------------------------------------------------------------------------
section "$(t "阶段 0 完成" "Stage 0 done")" "$(t "快照安全网就绪" "snapshot safety net ready")"

# 【注意】这里必须用 if 不能用 `[ ... ] && info_kv`：脚本开了 set -e，
# 判断为假的 && 列表会返回非零，直接把脚本带崩。
if [ "$HOME_FSTYPE" = "btrfs" ]; then
    info_kv "$(t "home 快照配置" "home snapshots")" "snapper -c home" "$(t "描述标记 $SNAP_HOME_DESC" "tag $SNAP_HOME_DESC")"
else
    info_kv "$(t "home 快照配置" "home snapshots")" "$(t "无" "none")" "$(t "家目录就在 root 子卷里，root 的快照覆盖它" "home is inside the root subvolume — covered by root snapshots")"
fi
info_kv "$(t "自动快照" "auto snapshots")" "$(t "每小时 3 个" "3 per hour")" "$(t "由 snapper-timeline.timer 负责" "via snapper-timeline.timer")"

log "$(t "以后怎么退回来：" "how to roll back:")"
log "  snapper -c root list"
log "  sudo snapper -c root undochange <编号>..0"
log "$(t "也可以开机时在 GRUB 的 Snapshots 子菜单里进快照系统；-c root 换成 -c home 就是家目录" "you can also boot from the GRUB Snapshots submenu; use -c home for /home")"

if [ "$ROOT_SNAP_OK" -eq 0 ]; then
    error "$(t "root 还原点没打上，安全网不完整。先修 snapper 再重跑本模块。" "no root snapshot — the safety net is incomplete. Fix snapper and rerun.")"
    exit 1
fi

success "$(t "阶段 0 完成，系统此刻的状态已经存下来了" "Stage 0 done — the current system state is saved")"
