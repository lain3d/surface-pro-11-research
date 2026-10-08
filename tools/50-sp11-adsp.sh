# sp11: boot the full ADSP image before root is mounted.
#
# Installed into the initramfs at  /var/lib/dracut/hooks/pre-mount/50-sp11-adsp.sh
#
# WHY HERE
#
# Booting qcadsp8380.mbn restarts charger_pd, which owns USB-C power delivery.
# About 85 ms after charger_pd comes back up the Type-C port drops whatever is
# attached - measured twice on 2026-08-06, at 41.14 -> 41.22 s and 44.20 ->
# 44.29 s. The disk then re-attaches on its own about 1.5 s later. That is
# survivable only if nothing is holding the disk when it happens, which is why
# this runs at pre-mount: dracut mounts root by UUID afterwards, so the device
# coming back as sdb instead of sda does not matter.
#
# WHY IT IS WORTH THE TROUBLE
#
# An ADSP that is *attached* to the firmware's own image never brings up the
# adsp_apps glink channel, so gprsvc never registers and every LPASS device sits
# in deferred probe forever. Booting the full 21 MiB image does register
# gprsvc:service:2:1 and 2:2. Audio needs the restart; there is no way around it.
#
# THE RULES THIS FILE OBEYS, EACH LEARNED THE HARD WAY
#
#   * Hooks are SOURCED by /usr/bin/dracut-pre-mount. A bare `exit` would abort
#     dracut-pre-mount before its own cleanup. Everything is inside a function
#     and uses `return`.
#   * /bin/sh here is dash, not bash. POSIX only: no arrays, no [[ ]], no
#     `local -n`, no ${var,,}.
#   * The initramfs has no printf, no dd, no bash. It does have sh, modprobe,
#     insmod, mount, umount, cp, mkdir, cat, sleep, udevadm, blkid, ln, rm.
#   * There is NO vfat module in the initrd, so the Windows ESP cannot be
#     mounted from here. Log to /dev/kmsg instead - sp11-winlog replays the whole
#     ring buffer once root is up, so nothing is lost.
#   * The initrd's own module tree is stamped 7.1.3-sp11-integ-* while the kernel
#     is 7.1.3-sp11-stockcfg-*. modprobe resolves against `uname -r` and finds
#     nothing, so the modules are staged out of the mounted root first - but NOT
#     into /lib/modules. On integ37 not one byte landed there while 25 MiB of
#     firmware copied fine off the same mount in the same instant. Stage flat
#     into /run and insmod by absolute path; /run is the part that works.
#   * firmware_class.path is KERNEL state and /run is carried across switch-root,
#     so anything this hook leaves set stays set in userspace. On 2026-08-06 that
#     turned a failed hook into a *worse* boot than no hook at all: modprobe
#     failed here, the path stayed pointing at the staged image, and udev loaded
#     qcom_q6v5_pas at 40 s with root mounted rw - the ADSP restarted, the port
#     dropped, and ext4 aborted the journal. Every path below that arms now
#     deletes the staged tree before returning, so the path resolves nothing.
#
# ARMING
#
# By default this only PROBES: it logs what it finds and touches no hardware.
# Add  rd.sp11.adsp=1  to the kernel command line to actually restart the ADSP.
# That way one UKI serves both, and arming is a cmdline edit rather than a
# rebuild.
#
# rd.sp11.dp=1 used to do the DisplayPort connector reset from here. It cannot
# work: UCSI's initialisation is gated on the pmic_glink PDR "up" event, which
# only arrives when charger_pd restarts - so UCSI cannot read the port until
# after the very restart that destroys what we wanted to read. Measured twice:
# insmod at 4.07 s, silence, restart at 19.17 s, PDR up at 19.52 s, UCSI alive
# at 19.86 s. The reset lives in sp11-dp-reset.service instead.

sp11_adsp_hook() {
    sp11_log() { echo "sp11-adsp: $*" > /dev/kmsg 2>/dev/null || true; }

    # Undo the one piece of global state this hook sets. Called on every path
    # that returns after arming, successful or not.
    #
    # firmware_class.path cannot actually be cleared: a zero-byte write to a
    # sysfs attribute never reaches the store op, so `echo -n ""` is a silent
    # no-op, and anything non-empty just becomes a different bogus prefix.
    # Deleting the staged tree is what does the work - the loader skips a path
    # that does not resolve and falls through to /lib/firmware on the real root.
    sp11_defuse() {
        rm -rf /run/sp11fw /run/sp11mod 2>/dev/null || true
        sp11_log "staged firmware removed - firmware_class.path now resolves nothing"
    }

    _ran=/run/sp11-adsp-ran
    if [ -e "$_ran" ]; then
        sp11_log "already ran this boot, skipping"
        return 0
    fi
    : > "$_ran" 2>/dev/null

    read -r _up _idle < /proc/uptime 2>/dev/null || _up='?'
    sp11_log "pre-mount hook running at uptime ${_up}s"

    # ---- arm? -------------------------------------------------------------
    _armed=no
    read -r _cmdline < /proc/cmdline 2>/dev/null || _cmdline=
    for _a in $_cmdline; do
        case "$_a" in
            rd.sp11.adsp=1) _armed=yes ;;
            rd.sp11.adsp=0) _armed=no ;;
        esac
    done

    _uuid=
    for _a in $_cmdline; do
        case "$_a" in root=UUID=*) _uuid="${_a#root=UUID=}" ;; esac
    done
    [ -n "$_uuid" ] || { sp11_log "no root=UUID= on the cmdline; doing nothing"; return 0; }

    _rootdev=/dev/disk/by-uuid/$_uuid

    # ---- wait for the root device ----------------------------------------
    #
    # This hook is ordered After=dracut-initqueue.service, so the device should
    # already be here - but the disk attaches at ~1.3 s and initqueue has its own
    # timeout, so poll rather than assume.
    _i=0
    while [ "$_i" -lt 20 ]; do
        [ -e "$_rootdev" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    if [ ! -e "$_rootdev" ]; then
        sp11_log "root device $_rootdev never appeared; doing nothing"
        return 0
    fi
    sp11_log "root device present after ${_i}s"

    # ---- is root actually on the port the restart is going to drop? --------
    #
    # This whole hook exists because the ADSP restart drops the USB-C port, and
    # doing that with root mounted rw aborts the ext4 journal. If root is on the
    # internal NVMe instead, none of that applies: the restart is harmless, the
    # waits below are pointless, and the hook is not really needed at all - a
    # normal userspace module load would do. It still works, so rather than bail
    # out, say so and skip the waiting.
    #
    # No readlink in this initramfs, so resolve through blkid and `pwd -P`,
    # which is a shell builtin and follows symlinks.
    _rootonusb=unknown
    _rootreal=$(blkid -U "$_uuid" 2>/dev/null)
    if [ -n "$_rootreal" ]; then
        _rootbn=${_rootreal##*/}
        _rootsys=$(cd "/sys/class/block/$_rootbn" 2>/dev/null && pwd -P)
        case "$_rootsys" in
            "")                    _rootonusb=unknown ;;
            *.usb/*|*/usb[0-9]*/*) _rootonusb=yes ;;
            *)                     _rootonusb=no ;;
        esac
        sp11_log "root is $_rootreal, on USB: $_rootonusb"
    else
        sp11_log "blkid could not resolve the root UUID; assuming it is on USB"
    fi

    # ---- stage firmware and modules out of root --------------------------
    #
    # The CDSP image is staged too. firmware_class.path is searched first and
    # /lib/firmware does not exist in the initramfs, so if qccdsp8380.mbn were
    # left behind the CDSP would fail its one and only auto-boot at probe and
    # stay down for the rest of the session.
    _mnt=/run/sp11root
    _fwsub=lib/firmware/qcom/x1e80100/microsoft/Denali
    _fwstage=/run/sp11fw
    _denali=$_fwstage/qcom/x1e80100/microsoft/Denali
    _kver=$(uname -r)

    mkdir -p "$_mnt" 2>/dev/null
    if ! mount -o ro "$_rootdev" "$_mnt" 2>/dev/null; then
        sp11_log "could not mount root read-only; doing nothing"
        return 0
    fi

    _src=$_mnt/$_fwsub
    mkdir -p "$_denali" 2>/dev/null

    # The ADSP image is deliberately hidden on the root as .disabled, so that a
    # normal boot attaches instead of restarting. Stage it back under its real
    # name into tmpfs; the copy on disk is never touched.
    _got=no
    for _f in qcadsp8380.mbn qcadsp8380.mbn.disabled; do
        if [ -f "$_src/$_f" ]; then
            cp "$_src/$_f" "$_denali/qcadsp8380.mbn" 2>/dev/null && _got=yes && break
        fi
    done
    _cdsp=no
    if [ -f "$_src/qccdsp8380.mbn" ]; then
        cp "$_src/qccdsp8380.mbn" "$_denali/qccdsp8380.mbn" 2>/dev/null && _cdsp=yes
    fi
    for _f in adsp_dtb.mbn cdsp_dtb.mbn adspr.jsn adsps.jsn adspua.jsn \
              battmgr.jsn cdspr.jsn; do
        [ -f "$_src/$_f" ] && cp "$_src/$_f" "$_denali/$_f" 2>/dev/null
    done

    # ---- stage the modules, into /run and NOT into /lib/modules ------------
    #
    # 2026-08-06, integ37: nothing at all landed under /lib/modules/$kver -
    # `inventory: modules.dep=no remoteproc_kos=0 pas=no` - while 25 MiB of
    # firmware copied off the same mount, with the same cp, in the same
    # instant. The destination is the only difference. /run works and
    # /lib/modules/$kver (reached through the initramfs's /lib -> usr/lib
    # symlink) does not, and rather than keep guessing why, stop needing it:
    # insmod takes an absolute path and does not care where the file lives.
    #
    # The closure is seven modules, order from `modprobe --show-depends` on a
    # complete tree. qcom_glink_smem is builtin in this config and will simply
    # not be there; that is fine and logged.
    _msrc=$_mnt/lib/modules/$_kver
    _mstage=/run/sp11mod
    _mods=0

    # Load a staged module by absolute path, saying what went wrong if it did.
    # Defined here because both the DisplayPort work and the q6v5 fallback below
    # use it, and the DisplayPort work runs first.
    sp11_insmod_one() {
        _im=$1
        for _if in "$_mstage/$_im".ko "$_mstage/$_im".ko.*; do
            [ -f "$_if" ] || continue
            if insmod "$_if" 2>/run/sp11-insmod.err; then
                sp11_log "insmod $_im ok"
            else
                while read -r _iline; do
                    [ -n "$_iline" ] && sp11_log "insmod $_im: $_iline"
                done < /run/sp11-insmod.err
            fi
            return 0
        done
        sp11_log "insmod $_im: not staged"
        return 1
    }

    stage_ko() {
        _sk=$1
        _sd=$2
        for _sf in "$_msrc/$_sd/$_sk".ko "$_msrc/$_sd/$_sk".ko.*; do
            [ -f "$_sf" ] || continue
            cp "$_sf" "$_mstage/${_sf##*/}" 2>/dev/null && _mods=$((_mods + 1))
            return 0
        done
        return 1
    }

    if [ -d "$_msrc" ]; then
        mkdir -p "$_mstage" 2>/dev/null
        stage_ko mdt_loader       kernel/drivers/soc/qcom
        stage_ko qcom_glink_smem  kernel/drivers/rpmsg
        stage_ko qcom_common      kernel/drivers/remoteproc
        stage_ko qcom_sysmon      kernel/drivers/remoteproc
        stage_ko qcom_q6v5        kernel/drivers/remoteproc
        stage_ko qcom_pil_info    kernel/drivers/remoteproc
        stage_ko qcom_q6v5_pas    kernel/drivers/remoteproc
    else
        sp11_log "no module tree at $_msrc"
    fi

    # Keep trying /lib/modules as well, purely so modprobe has a chance and so
    # mkdir finally gets to say what is wrong with it. Nothing depends on it.
    _mdst=/lib/modules/$_kver
    if [ -d "$_msrc" ]; then
        if mkdir -p "$_mdst" 2>/run/sp11-mkdir.err; then
            for _f in modules.dep modules.dep.bin modules.alias modules.alias.bin \
                      modules.symbols modules.symbols.bin modules.builtin \
                      modules.builtin.bin modules.builtin.alias.bin \
                      modules.builtin.modinfo modules.softdep modules.order; do
                [ -f "$_msrc/$_f" ] && cp "$_msrc/$_f" "$_mdst/$_f" 2>/dev/null
            done
            for _d in kernel/drivers/remoteproc kernel/drivers/soc/qcom kernel/drivers/rpmsg; do
                if [ -d "$_msrc/$_d" ]; then
                    mkdir -p "$_mdst/$_d" 2>/dev/null
                    cp "$_msrc/$_d"/* "$_mdst/$_d/" 2>/dev/null
                fi
            done
        else
            while read -r _line; do
                [ -n "$_line" ] && sp11_log "mkdir $_mdst: $_line"
            done < /run/sp11-mkdir.err
        fi
    fi

    umount "$_mnt" 2>/dev/null || sp11_log "WARNING: could not unmount $_mnt"

    sp11_log "staged adsp=$_got cdsp=$_cdsp modules=$_mods/7 for $_kver"

    # ---- inventory --------------------------------------------------------
    #
    # Report what actually landed, not whether the source directory existed -
    # that distinction is what cost integ36 and integ37.
    _pas=no
    for _f in "$_mstage"/qcom_q6v5_pas.ko "$_mstage"/qcom_q6v5_pas.ko.*; do
        [ -f "$_f" ] && _pas=$_f && break
    done
    _dep=no
    [ -s "$_mdst/modules.dep" ] && _dep=yes
    sp11_log "inventory: run_stage_pas=$_pas libmodules_dep=$_dep"

    if [ "$_got" != yes ]; then
        sp11_log "no ADSP firmware staged; doing nothing"
        return 0
    fi

    if [ "$_armed" != yes ]; then
        sp11_log "PROBE ONLY - add rd.sp11.adsp=1 to arm. Nothing was touched."
        return 0
    fi

    # ---- arm: point firmware_class at the staged copy and boot the ADSP ---
    echo -n "$_fwstage" > /sys/module/firmware_class/parameters/path 2>/dev/null ||
        { sp11_log "cannot set firmware_class path; doing nothing"; return 0; }

    if [ "$_rootonusb" = no ]; then
        sp11_log "loading qcom_q6v5_pas - root is not on the Type-C port, so the"
        sp11_log "  drop is harmless and this hook is not strictly needed here"
    else
        sp11_log "loading qcom_q6v5_pas - the port is expected to drop the disk"
    fi

    # modprobe first, with its complaint captured - it costs 2 ms and would be
    # the tidier path if /lib/modules ever starts working. It did not on integ37:
    # "FATAL: Module qcom_q6v5_pas not found in directory /lib/modules/...",
    # because nothing had landed there.
    #
    # The fallback needs no index and no module directory at all: every file was
    # staged flat into /run/sp11mod, which demonstrably works. Order is
    # modprobe's own, from `--show-depends` on a complete tree: dependencies
    # first, and qcom_common BEFORE qcom_sysmon. The modules are .ko.zst and
    # kmod decompresses them.
    _loaded=no
    if modprobe qcom_q6v5_pas 2>/run/sp11-modprobe.err; then
        _loaded=modprobe
    else
        while read -r _line; do
            [ -n "$_line" ] && sp11_log "modprobe: $_line"
        done < /run/sp11-modprobe.err
        sp11_log "modprobe failed - falling back to insmod by path"

        sp11_insmod_one mdt_loader
        sp11_insmod_one qcom_glink_smem   # builtin in this config; harmless
        sp11_insmod_one qcom_common
        sp11_insmod_one qcom_sysmon
        sp11_insmod_one qcom_q6v5
        sp11_insmod_one qcom_pil_info

        if [ "$_pas" != no ]; then
            if insmod "$_pas" 2>/run/sp11-insmod.err; then
                _loaded=insmod
            else
                while read -r _line; do
                    [ -n "$_line" ] && sp11_log "insmod: $_line"
                done < /run/sp11-insmod.err
            fi
        else
            sp11_log "qcom_q6v5_pas.ko is not in the staged tree"
        fi
    fi

    if [ "$_loaded" = no ]; then
        sp11_log "COULD NOT LOAD qcom_q6v5_pas - leaving the ADSP alone"
        sp11_defuse
        return 0
    fi
    sp11_log "qcom_q6v5_pas loaded via $_loaded"

    # find the ADSP and wait for it to run
    _adsp=
    _i=0
    while [ "$_i" -lt 30 ]; do
        for _r in /sys/class/remoteproc/remoteproc*; do
            [ -e "$_r/name" ] || continue
            read -r _nm < "$_r/name"
            [ "$_nm" = adsp ] && _adsp=$_r
        done
        if [ -n "$_adsp" ]; then
            read -r _st < "$_adsp/state" 2>/dev/null || _st='?'
            [ "$_st" = running ] && break
        fi
        sleep 1
        _i=$((_i + 1))
    done
    sp11_log "adsp=${_adsp:-none} state=${_st:-none} after ${_i}s"

    # ---- wait for the disk to come back ----------------------------------
    #
    # udev is alive here (it is RAM-backed), so the by-uuid symlink should be
    # recreated. Measured at 1.5 s twice; allow far more, and settle afterwards
    # so dracut-mount finds the link.
    #
    # Skipped when root is not on the Type-C port: nothing took it away, so
    # there is nothing to wait for.
    if [ "$_rootonusb" = no ]; then
        sp11_log "root is not on the Type-C port - not waiting for it to return"
    else
    _i=0
    while [ "$_i" -lt 45 ]; do
        [ -e "$_rootdev" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    fi

    if [ -e "$_rootdev" ]; then
        sp11_log "ROOT DEVICE IS BACK after ${_i}s - continuing the boot"
        udevadm settle --timeout=10 2>/dev/null || true

    else
        sp11_log "ROOT DEVICE DID NOT RETURN within ${_i}s - the boot will fail"
        sp11_log "power-cycle and boot the UKI without rd.sp11.adsp=1"
    fi

    # audio is the point of all this: did the channel appear?
    for _d in /sys/bus/rpmsg/devices/*glink-edge.adsp_apps*; do
        [ -e "$_d" ] && sp11_log "adsp_apps is present - gpr can bind, audio is reachable"
    done

    for _r in /sys/class/remoteproc/remoteproc*; do
        [ -e "$_r/name" ] || continue
        read -r _nm < "$_r/name"
        read -r _st2 < "$_r/state" 2>/dev/null || _st2='?'
        sp11_log "remoteproc ${_r##*/} name=$_nm state=$_st2"
    done

    # The images are loaded; nothing else should resolve firmware out of tmpfs,
    # least of all a second qcom_q6v5_pas probe once the real root is up.
    sp11_defuse
    return 0
}

sp11_adsp_hook
