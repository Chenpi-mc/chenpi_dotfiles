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
# 这一步干三件事：
#   1. 装 snapper，给 /（btrfs 的 @ 子卷）和 /home（@home）各建一份快照配置
#   2. 让 GRUB 记住上次启动项，并把「快照子菜单」集成进 GRUB 菜单（grub-btrfs）
#   3. 打一个「装系统之前」的还原点，后面任何一步翻车都能退回来
#
# 为什么必须排在最前面：快照要在系统还干净的时候先打，等 01a / 02b 塞完一堆包
# 再打就失去意义了。这个模块本身只装 snapper（+ grub-btrfs），不碰别的。
#
# 和参考版的区别（逐条说明，方便以后对着看）：
#   - 不强制 root 运行：用 as_root 包住要动系统的命令，普通用户也能跑
#   - 装包走 pac_install（顺手登记装后对账清单），不写裸 pacman
#   - 不引用他的 resources/ 目录，也不部署他私有的 shorin-undochange 脚本；
#     回滚直接用 snapper / btrfs-assistant 的命令行（文末会打印用法）
#   - 不创建用户、不假设用户名：TARGET_USER / TARGET_HOME 由主控 detect_target_user
#     设置并 export，这里直接读
#   - 还原点的标记字符串换成我们自己的（见下面 SNAP_*_DESC），不沿用他的英文串
#   - GRUB 目录定位：他那边是 00-utils.sh 里的 ensure_grub_dir_link()，
#     我们的公共库没有这个函数，所以在这里就地展开成一段（不新增函数，
#     共用库的约定是不重复造函数）
# ==============================================================================

require_arch

# 本次运行共用一个时间戳：所有 .bak 备份都带它，方便按时间点整体回退
BACKUP_TS="$(date +%Y%m%d-%H%M%S)"

# ---- 还原点的描述文本（标记）----
# 重复运行时靠这两个字符串判断「这个还原点是不是已经打过了」，所以改字串
# 等于换标记，会再多打一个快照。想换名字就改这里，注释里的说明一起改。
SNAP_ROOT_DESC="chenpi-setup-前"
SNAP_HOME_DESC="chenpi-setup-前"

# ---- snapper 调参 ----
# 取值沿用参考版：家用笔记本够用，不会把盘塞满。
# 说明几个关键的：
#   TIMELINE_LIMIT_HOURLY=3 时间线快照只留最近 3 小时，配清理 timer 自动滚
#   NUMBER_LIMIT=10         手动快照最多留 10 个（打还原点这类）
#   ALLOW_GROUPS=wheel      wheel 组能看/管快照，btrfs-assistant 之类的 GUI 要用
# 嫌 home 时间线快照占地方（家目录数据变动大、缓存多）就把 TIMELINE_CREATE 改成 no，
# 只留手动还原点 —— 改 SNAP_SETTINGS 一处即可，root 和 home 共用这份。
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

# 状态位：GRUB 那段能不能动（1=可以，0=布局不对，别乱写）
GRUB_OK=1
# 状态位：root 还原点有没有打上（0 = 没打上，最后要报错退出）
ROOT_SNAP_OK=1

section "阶段 0" "Btrfs 快照安全网初始化"
info_kv "配置仓库" "$REPO_ROOT"
# 【注意】本模块动的是磁盘和引导，其实不需要用户信息（TARGET_USER / TARGET_HOME
# 由主控 detect_target_user 设置并 export），这里只是打出来方便对着日志看。
# 用 ${X:-} 兜底是因为脚本开了 set -u：单独跑本模块时读到空变量直接就崩了。
info_kv "目标用户" "${TARGET_USER:-未设置}" "${TARGET_HOME:-}"

# ------------------------------------------------------------------------------
# 0. 环境判断：根分区不是 btrfs 就整套跳过
# ------------------------------------------------------------------------------
# 快照依赖 btrfs 的 CoW，ext4 之类没有等价物，直接返回而不是报错：
# 这是「不适用」，不是「失败」，后面的模块照常跑。
ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
if [ "$ROOT_FSTYPE" != "btrfs" ]; then
    warn "根分区不是 Btrfs（检测到 ${ROOT_FSTYPE:-未知}），快照安全网整套跳过"
    log "非 Btrfs 没有 CoW 快照，这是不适用、不是报错；后面的模块不受影响"
    exit 0
fi
success "根分区是 Btrfs，继续配置快照安全网"

# ------------------------------------------------------------------------------
# 1. 先定位 GRUB 目录：/boot/grub 有可能根本不存在
# ------------------------------------------------------------------------------
# 【为什么要这一步】archinstall 在「没有独立 /boot 分区 + ESP 挂在 /boot 以外
# （比如 /efi）」时会给 grub-install 传 --boot-directory=$ESP，于是 GRUB 的模块、
# grub.cfg、grubenv 全都落在 $ESP/grub，而 /boot/grub 不存在。
# 而 grub-mkconfig / grub-editenv / grub-btrfs 都把 /boot/grub 写死在代码里，
# 于是我们做的所有 GRUB 配置都会「写到一个没人读的地方」，看起来成功其实无效。
#
# 处理方式（只做加法，绝不删改既有东西）：
#   - 只在 /boot/grub 完全不存在时，补一个软链指向真正的 GRUB 目录
#   - 必须链目录而不是文件：这些工具都是「写 .tmp 再 rename」的写法，
#     文件级软链会被 rename 直接替换掉，链一次坏一次
#   - 判据用模块目录（*/normal.mod）而不是 grub.cfg：只有 grub-install 会写
#     模块目录，grub.cfg 谁都能生成，拿它当判据会误判
#   - /boot/grub 在标准布局下本来就存在（比如 ESP 直接挂 /boot），那就什么都不做
section "安全网" "定位 GRUB 目录"

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
        # 标准布局：GRUB 不在 ESP 里，/boot/grub 应该是真实存在的目录
        log "GRUB 不在 ESP 里，按标准布局处理（/boot/grub）"
    elif [ -e "/boot/grub" ] || [ -L "/boot/grub" ]; then
        # /boot/grub 已存在（真目录 / 软链 / 悬空软链）→ 一律不碰
        if [ -d "/boot/grub" ] && [ ! -L "/boot/grub" ] \
           && ! compgen -G "/boot/grub/*/normal.mod" >/dev/null 2>&1; then
            # 唯一的例外：它是个没有模块的空壳目录，说明布局其实是错的。
            # 修它要删既有目录，超出本模块职责（而且风险高），只提醒人工处理。
            warn "GRUB 实际装在 $ESP_GRUB，但 /boot/grub 是个没有模块的空目录"
            warn "这种布局下改 GRUB 配置不会生效，需要人工处理："
            warn "  rm -rf /boot/grub && ln -sfn $ESP_GRUB /boot/grub"
            GRUB_OK=0
        else
            log "/boot/grub 已存在（真目录或软链），不碰"
        fi
    else
        log "GRUB 装在 ESP 里（--boot-directory 布局），/boot/grub 不存在，补一个软链"
        log "链上之后 grub-mkconfig / grub-editenv / grub-btrfs 才会写到真正被读取的位置"
        if as_root ln -sfn "$ESP_GRUB" "/boot/grub"; then
            success "已建立软链：/boot/grub -> $ESP_GRUB"
        else
            warn "软链没建成，后面的 GRUB 配置会写到没被读取的位置"
            GRUB_OK=0
        fi
    fi
else
    log "没装 grub-mkconfig，跳过 GRUB 目录处理（systemd-boot / limine 之类属正常）"
fi

# ------------------------------------------------------------------------------
# 2. 装 snapper
# ------------------------------------------------------------------------------
# 只装 snapper 本体，不装任何「附带工具」；GUI（btrfs-assistant）交给用户自己决定，
# 这里只在最后提示一下。
section "第 1 步" "安装 snapper"

if has_pkg snapper; then
    success "snapper 已经装过了，跳过"
else
    log "装 snapper（pac_install 会自动登记到装后对账清单）"
    pac_install snapper || true
    if has_pkg snapper; then
        success "snapper 装好了"
    else
        error "snapper 装不上，快照安全网没法继续"
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 3. root（/）快照配置
# ------------------------------------------------------------------------------
# 幂等判据：snapper list-configs 里已经有名为 root 的配置 → 直接跳过，
# 绝不去动已有的配置（用户可能自己调过参数）。
section "第 2 步" "配置 root 快照"

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    success "snapper 的 root 配置已存在，跳过创建（不动你现有的参数）"
else
    # 创建配置前必须清掉已存在的 /.snapshots：snapper 要求自己建这个子卷，
    # 占着位置就创建失败。三种情况分开处理，只有「普通目录」才会被挪走：
    #   - 已经是挂载点 → 说明 fstab 里配好了，保留
    #   - 已经是 btrfs 子卷 → 保留（btrfs 子卷的根 inode 号固定是 256）
    #   - 普通目录 → 改名挪到一边（不删！可手动恢复）
    if [ -e "/.snapshots" ] || [ -L "/.snapshots" ]; then
        if [ "$(findmnt -n -o TARGET -T /.snapshots 2>/dev/null || true)" = "/.snapshots" ]; then
            log "/.snapshots 已经是一个挂载点，保留不动"
        elif [ "$(stat -c %i /.snapshots 2>/dev/null || echo 0)" = "256" ]; then
            log "/.snapshots 已经是 btrfs 子卷，保留不动"
        else
            log "/.snapshots 是个普通目录，snapper 建不了子卷，先改名挪到一边"
            log "注意：这里用 mv 不用 rm —— 挪走还能手动搬回来，删掉就没了"
            if as_root mv "/.snapshots" "/.snapshots.bak-${BACKUP_TS}"; then
                warn "原 /.snapshots 已挪到 /.snapshots.bak-${BACKUP_TS}，确认没用可以自己删"
            else
                warn "挪走 /.snapshots 失败，snapper 多半建不了配置（下面能看到结果）"
            fi
        fi
    fi

    log "创建 root 快照配置（会在 / 下新建 .snapshots 子卷，并追加一条 fstab 挂载项）"
    if exe as_root snapper -c root create-config /; then
        success "root 配置创建好了"
    else
        warn "root 配置创建失败，后面打还原点会跳过"
    fi
fi

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    # set-config 是 snapper 自己的官方接口，幂等：重复设同样的值无副作用。
    # 【为什么不备份 /etc/snapper/configs/root 再改】那个目录里每个文件都会被
    # snapper 当成一份配置，塞 .bak 进去会多出一份名字乱七八糟的「配置」，
    # 所以这里一律不走手改文件的路子。
    log "写入 root 的推荐参数（时间线快照 + 自动清理 + wheel 组可读）"
    exe as_root snapper -c root set-config "${SNAP_SETTINGS[@]}" || warn "参数没写全，但配置本身可用"

    log "启用两个 timer：时间线快照 + 自动清理（已启用的会被 systemd 忽略，重复跑安全）"
    exe as_root systemctl enable --now snapper-timeline.timer snapper-cleanup.timer \
        || warn "timer 没启用成功，自动快照/清理不会跑（手动快照不受影响）"
    success "root 快照配置就绪"
else
    ROOT_SNAP_OK=0
fi

# ------------------------------------------------------------------------------
# 4. home（/home）快照配置
# ------------------------------------------------------------------------------
# 只在 /home 确实是独立 btrfs 时做（CachyOS 的 @home 子卷就是这种）。
# 家目录里是我们真正在意的数据（dotfiles、文档），所以单独配一份。
section "第 3 步" "配置 home 快照"

HOME_FSTYPE="$(findmnt -n -o FSTYPE /home 2>/dev/null || true)"
if [ "$HOME_FSTYPE" != "btrfs" ]; then
    warn "/home 不是 btrfs（检测到 ${HOME_FSTYPE:-未知}），跳过 home 快照"
    log "这种情况多半是 /home 就在 root 子卷里，root 的快照已经覆盖它了"
else
    if as_root snapper list-configs 2>/dev/null | grep -q '^home '; then
        success "snapper 的 home 配置已存在，跳过创建"
    else
        if [ -e "/home/.snapshots" ] || [ -L "/home/.snapshots" ]; then
            if [ "$(findmnt -n -o TARGET -T /home/.snapshots 2>/dev/null || true)" = "/home/.snapshots" ]; then
                log "/home/.snapshots 已经是一个挂载点，保留不动"
            elif [ "$(stat -c %i /home/.snapshots 2>/dev/null || echo 0)" = "256" ]; then
                log "/home/.snapshots 已经是 btrfs 子卷，保留不动"
            else
                log "/home/.snapshots 是个普通目录，先改名挪到一边"
                if as_root mv "/home/.snapshots" "/home/.snapshots.bak-${BACKUP_TS}"; then
                    warn "原 /home/.snapshots 已挪到 /home/.snapshots.bak-${BACKUP_TS}"
                else
                    warn "挪走 /home/.snapshots 失败，home 配置多半建不起来"
                fi
            fi
        fi

        log "创建 home 快照配置（会在 /home 下新建 .snapshots 子卷）"
        if exe as_root snapper -c home create-config /home; then
            success "home 配置创建好了"
            exe as_root snapper -c home set-config "${SNAP_SETTINGS[@]}" || warn "参数没写全，但配置本身可用"
        else
            # /home 不是 btrfs 子卷时 snapper 会拒绝，这里只警告不中断
            warn "home 配置创建失败（/home 不是独立子卷时会这样），root 快照不受影响"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. GRUB：记住上次启动项 + 把快照子菜单集成进菜单
# ------------------------------------------------------------------------------
# 这里分三小块，每一块都会先判断「是不是已经做过了」：
#   5a. GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true —— 回滚快照后能记住启动项
#   5b. grub-btrfs —— 让 GRUB 菜单里出现 Snapshots 子菜单，可以直接进快照系统
#   5c. grubenv 环境块 —— 只有 /boot/grub 在 btrfs 上才需要（见下面的说明）
section "安全网" "GRUB 引导项记忆与快照菜单"

if [ "$GRUB_OK" -eq 1 ] && [ -f "/etc/default/grub" ] && command -v grub-mkconfig >/dev/null 2>&1; then
    # NEED_REGEN：这次是不是有必要重新生成 grub.cfg（改过配置、或新装了 grub-btrfs）
    NEED_REGEN=0

    # ---- 5a. 判断是不是 UKI 布局 ----
    # UKI（统一内核镜像）由 systemd-boot / kernel-install 自己管理条目，
    # GRUB_DEFAULT=saved 那套记忆在 UKI 下没有意义，还可能互相打架，所以跳过。
    UKI_ENABLED=0
    if grep -qsE '^[[:space:]]*[[:alnum:]_]+_uki[[:space:]]*=' /etc/mkinitcpio.d/*.preset 2>/dev/null \
       || grep -qsE '^[[:space:]]*layout[[:space:]]*=[[:space:]]*uki([[:space:]]|$)' /etc/kernel/install.conf 2>/dev/null; then
        UKI_ENABLED=1
    fi

    if [ "$UKI_ENABLED" -eq 1 ]; then
        log "检测到 UKI 布局，跳过 GRUB_DEFAULT=saved（UKI 下这套记忆机制不适用）"
    elif grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub \
      && grep -qE '^GRUB_SAVEDEFAULT=(true|"true")' /etc/default/grub; then
        success "GRUB 的 savedefault 已经配好了，跳过（重复跑不会重复改）"
    else
        log "要改 /etc/default/grub：GRUB_DEFAULT=saved + GRUB_SAVEDEFAULT=true"
        log "为什么：回滚快照后 GRUB 要能记住「上次从哪个项启动」，否则每次都跳回默认项"
        # 改系统配置文件前先留一份原样备份
        if as_root cp -a /etc/default/grub "/etc/default/grub.bak-${BACKUP_TS}"; then
            success "原文件已备份：/etc/default/grub.bak-${BACKUP_TS}"
        else
            warn "备份 /etc/default/grub 失败！先别继续改，请手动复制一份再重跑"
            error "拒绝在没有备份的情况下改引导配置"
            exit 1
        fi

        # 写失败也不在这里中断，统一在写完之后做一次校验（见下面），
        # 校验不过就用备份回滚 —— 半改半不改的 grub 配置比不改更危险。
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

        # 校验：两项都真的写进去了才算成功
        if grep -qE '^GRUB_DEFAULT=saved' /etc/default/grub \
           && grep -qE '^GRUB_SAVEDEFAULT=(true|"true")' /etc/default/grub; then
            NEED_REGEN=1
            success "已写入 GRUB_DEFAULT=saved / GRUB_SAVEDEFAULT=true"
        else
            warn "写入没生效（可能 /etc/default/grub 权限或磁盘有问题），用备份恢复原样"
            as_root cp -a "/etc/default/grub.bak-${BACKUP_TS}" /etc/default/grub || true
            error "/etc/default/grub 改不动，GRUB 记忆启动项这一步跳过；原文件已还原"
        fi
    fi

    # ---- 5b. grub-btrfs：GRUB 菜单里的快照子菜单 ----
    # 装了它 + 启用 grub-btrfsd，快照一变就自动刷新 grub.cfg，
    # 开机时可以直接选「进入某个快照的系统」。
    if has_pkg grub-btrfs; then
        log "grub-btrfs 已经装过了，跳过"
    else
        log "装 grub-btrfs（GRUB 快照子菜单）+ inotify-tools（grub-btrfsd 的依赖）"
        log "这两个包在官方源里，不需要 AUR；pac_install 会自动登记对账清单"
        pac_install grub-btrfs inotify-tools || true
        if has_pkg grub-btrfs; then
            success "grub-btrfs 装好了"
            NEED_REGEN=1
        else
            warn "grub-btrfs 没装上，GRUB 菜单里不会有快照子菜单（快照本身照常工作）"
            warn "补救：装好源之后重跑本模块，或者手动 pacman -S --needed grub-btrfs && grub-mkconfig -o /boot/grub/grub.cfg"
        fi
    fi

    if has_pkg grub-btrfs; then
        log "启用 grub-btrfsd（监听快照目录，快照一变就刷新 GRUB 菜单）"
        exe as_root systemctl enable --now grub-btrfsd.service \
            || warn "grub-btrfsd 没起来，快照子菜单要手动 grub-mkconfig 才刷新"
    fi

    # ---- 5b-2. 重新生成前先看一眼 Windows 双系统条目会不会丢 ----
    # 这台机器有 Windows 双系统，grub-mkconfig 时不查 os-prober 就会少 Windows 项。
    # 我们只在「本来就用不了 os-prober」时提醒，不擅自去改开关（那是 02c 的活）。
    if ! command -v os-prober >/dev/null 2>&1; then
        warn "本机没装 os-prober，重新生成 GRUB 菜单后可能看不到 Windows 启动项"
        warn "不慌：02c-dualboot-fix 模块会专门修这个，修完菜单里就有了"
    elif grep -qE '^GRUB_DISABLE_OS_PROBER=(true|"true")' /etc/default/grub; then
        warn "GRUB_DISABLE_OS_PROBER=true，重新生成菜单后 Windows 项不会出现"
        warn "同样交给 02c-dualboot-fix 处理"
    fi

    # ---- 5b-3. 真正重新生成 grub.cfg ----
    # 只有「改过东西」才重生成：反复生成没意义，还在动引导（改坏风险不为零）。
    if [ "$NEED_REGEN" -eq 1 ]; then
        GRUB_CFG_BACKUP_OK=1
        if [ -f "/boot/grub/grub.cfg" ]; then
            if as_root cp -a /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak-${BACKUP_TS}"; then
                success "旧菜单已备份：/boot/grub/grub.cfg.bak-${BACKUP_TS}"
            else
                # 备份失败说明 /boot 有问题（只读 / 满了）。这种情况下重新生成
                # 有可能写坏 grub.cfg 导致开不了机，宁可不做。
                warn "旧菜单备份失败（/boot 只读或空间不足），这次不重新生成菜单更稳妥"
                GRUB_CFG_BACKUP_OK=0
            fi
        else
            log "还没有 /boot/grub/grub.cfg（首次生成），不需要备份"
        fi
        if [ "$GRUB_CFG_BACKUP_OK" -eq 1 ]; then
            log "重新生成 GRUB 菜单（会覆盖 /boot/grub/grub.cfg，所以上面先备份了）"
            # LANG 固定成英文，避免 grub-mkconfig 吐中文把菜单项搞乱
            exe as_root env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg \
                || warn "grub-mkconfig 失败，用备份的 grub.cfg.bak-${BACKUP_TS} 顶回去再排查"
        else
            log "跳过生成菜单；修好 /boot 之后重跑本模块，或手动 grub-mkconfig -o /boot/grub/grub.cfg"
        fi
    else
        log "GRUB 配置这次没改动，跳过重新生成菜单"
    fi

    # ---- 5c. Btrfs 上的 grubenv 环境块 ----
    # GRUB 能就地改 FAT/ext，但 btrfs 不支持这种局部改写，所以要先写一次让
    # grubenv 里预留出环境块（env_block=），savedefault 才存得住。
    # 若 /boot/grub 不在 btrfs 上（比如 ESP 直接挂 /boot 的常见布局），
    # GRUB 本来就能直接写，无需处理 —— 我们判断后直接说明并跳过。
    GRUB_DIR_FSTYPE="$(findmnt -n -o FSTYPE -T /boot/grub 2>/dev/null || true)"
    if [ "$GRUB_DIR_FSTYPE" = "btrfs" ] && [ "$UKI_ENABLED" -eq 0 ] \
       && command -v grub-editenv >/dev/null 2>&1; then
        if as_root grub-editenv - list 2>/dev/null | grep -q '^env_block='; then
            success "grubenv 里已经预留过环境块，跳过（重复跑不会重写）"
        else
            log "grubenv 在 btrfs 上，先写一次把环境块预留出来"
            exe as_root grub-editenv - set ok=1 || warn "grub-editenv 写入失败"
            if as_root grub-editenv - list 2>/dev/null | grep -q '^env_block='; then
                success "环境块预留成功，savedefault 可以正常落盘"
            else
                warn "grubenv 里还是没看到 env_block，savedefault 可能存不住（不影响正常启动）"
            fi
        fi
    elif [ -n "$GRUB_DIR_FSTYPE" ] && [ "$GRUB_DIR_FSTYPE" != "btrfs" ]; then
        log "/boot/grub 在 $GRUB_DIR_FSTYPE 上（不是 btrfs），GRUB 能直接写 grubenv，无需预留环境块"
    fi
else
    if [ "$GRUB_OK" -eq 0 ]; then
        warn "GRUB 目录布局异常（见上面的提醒），GRUB 相关配置全部跳过，等人工修好再重跑"
    else
        warn "没有 /etc/default/grub 或 grub-mkconfig，跳过 GRUB 相关配置"
        log "如果这台机器用的是 systemd-boot / limine，那属于正常情况"
    fi
fi

# ------------------------------------------------------------------------------
# 6. 打第一个还原点（装系统之前的干净状态）
# ------------------------------------------------------------------------------
# 这是本模块的核心产出：后面任何一步（装包、换配置、恢复 dotfiles）翻车，
# 都能回到这个点。幂等判据是「有没有同名的快照描述」，有了就跳过，
# 避免重跑一次多一个快照（btrfs 快照吃空间，虽然很省）。
section "第 4 步" "打「装系统之前」的还原点"

if as_root snapper list-configs 2>/dev/null | grep -q '^root '; then
    if as_root snapper -c root list --columns description 2>/dev/null | grep -Fqx "$SNAP_ROOT_DESC"; then
        success "root 上已经有还原点「$SNAP_ROOT_DESC」，跳过（重跑不会叠一堆快照）"
    else
        log "在 root 上打还原点，描述「$SNAP_ROOT_DESC」"
        if exe as_root snapper -c root create --type single --description "$SNAP_ROOT_DESC"; then
            success "root 还原点打好了，出问题可以退回来"
        else
            warn "root 还原点没打上"
            ROOT_SNAP_OK=0
        fi
    fi
else
    warn "没有 root 的 snapper 配置，跳过还原点"
    ROOT_SNAP_OK=0
fi

if as_root snapper list-configs 2>/dev/null | grep -q '^home '; then
    if as_root snapper -c home list --columns description 2>/dev/null | grep -Fqx "$SNAP_HOME_DESC"; then
        success "home 上已经有还原点「$SNAP_HOME_DESC」，跳过"
    else
        log "在 home 上打还原点，描述「$SNAP_HOME_DESC」"
        if exe as_root snapper -c home create --type single --description "$SNAP_HOME_DESC"; then
            success "home 还原点打好了"
        else
            # home 快照失败不致命（root 有就行），只警告
            warn "home 还原点没打上，不影响后续步骤"
        fi
    fi
else
    log "没有 home 的 snapper 配置，跳过 home 还原点"
fi

# 说明一下：本模块不往用户家目录写任何文件（snapper 的 home 配置也是 root 操作），
# 所以这里用不到 as_user —— 家目录的东西在后面 04-restore-config 里才动。

# ------------------------------------------------------------------------------
# 7. 收尾：告诉用户怎么回滚
# ------------------------------------------------------------------------------
section "阶段 0 完成" "快照安全网就绪"

# 【注意】这里必须用 if 不能用 `[ ... ] && info_kv`：脚本开了 set -e，
# 判断为假的 && 列表会返回非零，直接把脚本带崩。
if [ "$HOME_FSTYPE" = "btrfs" ]; then
    info_kv "home 快照配置" "snapper -c home" "描述标记 $SNAP_HOME_DESC"
else
    info_kv "home 快照配置" "无" "家目录就在 root 子卷里，root 的快照覆盖它"
fi
info_kv "自动快照" "每小时 3 个" "由 snapper-timeline.timer 负责"

log "以后翻车了怎么退回来（记一下）："
log "  1) 先看有哪些快照：      snapper -c root list"
log "  2) 退回到某个快照：      sudo snapper -c root undochange <快照编号>..0"
log "     （意思是「把系统文件恢复成那个快照的样子」，<编号>..0 里 0 代表当前系统）"
log "  3) 重启；也可以开机时在 GRUB 的 Snapshots 子菜单里直接进快照系统看一眼"
log "  想要图形界面回滚的话：   sudo pacman -S --needed btrfs-assistant"
log "  家目录同理，把 -c root 换成 -c home"

if [ "$ROOT_SNAP_OK" -eq 0 ]; then
    error "root 还原点没打上，安全网不完整。先看上面的日志排查，修好后重跑本模块。"
    exit 1
fi

success "阶段 0 完成。系统此刻的状态已经存下来了，后面的改动都有退路。"
