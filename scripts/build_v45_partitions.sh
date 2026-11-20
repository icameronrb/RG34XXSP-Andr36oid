#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
V43_PARTS="$BASE_DIR/releases/v43-partitions"
V44_VENDOR="$BASE_DIR/releases/v44-adaptive-ram-test/RG34XXSP-v44-adaptive-ram-test/RG34XXSP-v44-vendor.img"
OUT_DIR="$BASE_DIR/releases/v45-perf-partitions"
MNT="/tmp/rg34xx_v45_mnt"

mkdir -p "$OUT_DIR"
rm -rf "$MNT"
mkdir -p "$MNT/system" "$MNT/vendor" "$MNT/product"

echo "[1/6] Checking base partition images (system, vendor, product) in $OUT_DIR..."
[ -f "$OUT_DIR/RG34XXSP-v45-system.img" ] || cp -f "$V43_PARTS/p5_system.img" "$OUT_DIR/RG34XXSP-v45-system.img"
[ -f "$OUT_DIR/RG34XXSP-v45-vendor.img" ] || cp -f "$V44_VENDOR" "$OUT_DIR/RG34XXSP-v45-vendor.img"
[ -f "$OUT_DIR/RG34XXSP-v45-product.img" ] || cp -f "$V43_PARTS/p7_product.img" "$OUT_DIR/RG34XXSP-v45-product.img"

echo "[2/6] Mounting partition images RW..."
mount -o loop,rw "$OUT_DIR/RG34XXSP-v45-system.img" "$MNT/system"
mount -o loop,rw "$OUT_DIR/RG34XXSP-v45-vendor.img" "$MNT/vendor"
mount -o loop,rw "$OUT_DIR/RG34XXSP-v45-product.img" "$MNT/product"

cleanup() {
    sync
    umount "$MNT/system" 2>/dev/null || true
    umount "$MNT/vendor" 2>/dev/null || true
    umount "$MNT/product" 2>/dev/null || true
}
trap cleanup EXIT

set_selinux() {
    local ctx="$1"
    shift
    python3 -c '
import os, sys
ctx = sys.argv[1].encode("ascii") + b"\x00"
for p in sys.argv[2:]:
    os.setxattr(p, b"security.selinux", ctx, follow_symlinks=False)
' "$ctx" "$@"
}

echo "[3/6] Optimizing VENDOR partition..."
V="$MNT/vendor"

# 3.1 Update /vendor/build.prop
# Replace generic CPU variants with cortex-a53, configure 64-bit-only zygote64, disable benchmark/blur/stats
sed -i \
    -e 's/^ro\.bionic\.cpu_variant=.*/ro.bionic.cpu_variant=cortex-a53/' \
    -e 's/^ro\.bionic\.2nd_cpu_variant=.*/ro.bionic.2nd_cpu_variant=cortex-a53/' \
    -e 's/^dalvik\.vm\.isa\.arm64\.variant=.*/dalvik.vm.isa.arm64.variant=cortex-a53/' \
    -e 's/^dalvik\.vm\.isa\.arm\.variant=.*/dalvik.vm.isa.arm.variant=cortex-a53/' \
    -e 's/^ro\.zygote=.*/ro.zygote=zygote64/' \
    -e 's/^ro\.vendor\.product\.cpu\.abilist=.*/ro.vendor.product.cpu.abilist=arm64-v8a/' \
    -e 's/^ro\.vendor\.product\.cpu\.abilist32=.*/ro.vendor.product.cpu.abilist32=/' \
    -e 's/^ro\.vendor\.product\.cpu\.abilist64=.*/ro.vendor.product.cpu.abilist64=arm64-v8a/' \
    -e 's/^persist\.vendor\.p_benchmark=.*/persist.vendor.p_benchmark=false/' \
    -e 's/^persist\.vendor\.p_music=.*/persist.vendor.p_music=false/' \
    -e 's/^ro\.vendor\.rg34xx\.port_revision=.*/ro.vendor.rg34xx.port_revision=45/' \
    "$V/build.prop"

cat >> "$V/build.prop" << 'EOF'

# v45 Performance-First Optimizations
ro.surface_flinger.supports_background_blur=0
disable_blurs=true
ro.andr36oid.power_menu_stats=false
persist.sys.power_menu_stats=0
ro.config.webview_zygote_lazy=true
EOF
chown 0:0 "$V/build.prop"
chmod 0600 "$V/build.prop"
set_selinux "u:object_r:vendor_file:s0" "$V/build.prop"

# 3.2 Write optimized /vendor/etc/init/hw/init.sun50iw9p1.rc
cat > "$V/etc/init/hw/init.sun50iw9p1.rc" << 'EOF'
import /vendor/etc/init/hw/init.sun50iw9p1.usb.rc
# RG34XX SP v45 performance-first startup.
on early-init
    setrlimit memlock 8388608 8388608
    # Full CPU clock during boot; switched to schedutil on sys.boot_completed=1
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor performance

on init
    write /dev/kmsg RG34XXSP_VENDOR_REVISION=45
    mkdir /dev/graphics 0755 root graphics
    symlink /dev/fb0 /dev/graphics/fb0
    symlink /dev/mali0 /dev/mali
    insmod /vendor/lib/modules/mali_kbase.ko
    chown system graphics /dev/mali0
    chmod 0666 /dev/mali0
    chown system graphics /dev/ion
    chmod 0666 /dev/ion
    chown system graphics /dev/disp
    chmod 0660 /dev/disp
    chown system graphics /dev/fb0
    chmod 0660 /dev/fb0
    setprop ro.opengles.version 196610

    # Disable Transparent Huge Pages & tune VM for 1 GB handheld without swap
    write /sys/kernel/mm/transparent_hugepage/enabled never
    write /proc/sys/vm/min_free_kbytes 8192
    write /proc/sys/vm/page-cluster 0
    write /proc/sys/vm/compact_unevictable_allowed 0
    write /proc/sys/vm/oom_dump_tasks 0
    write /proc/sys/vm/dirty_background_ratio 5
    write /proc/sys/vm/dirty_ratio 15
    write /proc/sys/vm/dirty_expire_centisecs 3000
    write /proc/sys/vm/dirty_writeback_centisecs 500
    write /proc/sys/vm/vfs_cache_pressure 100

on fs
    exec u:r:shell:s0 root root -- /system/bin/sh /vendor/bin/rg34xx-grow-storage.sh
    mount_all /vendor/etc/fstab.sun50iw9p1

on post-fs-data
    mkdir /data/local 0751 root root
    mkdir /data/local/tmp 0771 shell shell
    # Route storage through kernel sdcardfs instead of userspace FUSE (MediaProvider)
    setprop persist.sys.fuse false
    setprop persist.sys.fflag.override.settings_fuse false
    # Bound RAM profiling before zygote starts; defaults survive failure.
    exec u:r:shell:s0 root root -- /system/bin/timeout 10 /system/bin/sh /vendor/bin/rg34xx-ram-profile.sh
    # Start framework ashmem HIDL allocator required by Allwinner OMX hardware decoder & Codec2 (upstream V48)
    start rg34xx-hidl-memory
    setprop vold.post_fs_data_done 1

on boot
    # Disable userdebug scheduler profiling & printk overhead
    write /proc/sys/kernel/sched_schedstats 0
    write /proc/sys/kernel/printk_devkmsg off
    write /proc/sys/kernel/randomize_va_space 0
    write /proc/sys/kernel/perf_cpu_time_max_percent 5
    write /proc/sys/kernel/sched_child_runs_first 1
    write /proc/sys/kernel/timer_migration 0
    write /sys/kernel/debug/tracing/tracing_on 0
    write /sys/kernel/tracing/tracing_on 0
    # Prevent Allwinner H700 un-wakeable mem suspend while keeping screen-off + 480MHz + radio-cut sleep
    write /sys/power/wake_lock rg34xx_no_mem_suspend
    # Keep wireless ADB TCP port 5555 enabled across reboots
    setprop service.adb.tcp.port 5555

    # MicroSD (TF1 & TF2) queue optimization
    write /sys/block/mmcblk0/queue/iostats 0
    write /sys/block/mmcblk0/queue/add_random 0
    write /sys/block/mmcblk0/queue/rotational 0
    write /sys/block/mmcblk0/queue/read_ahead_kb 512
    write /sys/block/mmcblk0/queue/nr_requests 256
    write /sys/block/mmcblk1/queue/iostats 0
    write /sys/block/mmcblk1/queue/add_random 0
    write /sys/block/mmcblk1/queue/rotational 0
    write /sys/block/mmcblk1/queue/read_ahead_kb 512

    # Cpuset partitioning for quad-core Cortex-A53
    write /dev/cpuset/top-app/cpus 0-3
    write /dev/cpuset/foreground/cpus 0-3
    write /dev/cpuset/background/cpus 0
    write /dev/cpuset/system-background/cpus 0-1
    write /dev/cpuset/restricted/cpus 0-1

# Internal RTL8821CS Bluetooth uses the stock H700 UART and power controller.
on boot
    setprop persist.vendor.bluetooth_port /dev/ttyS1
    setprop persist.log.tag.bluetooth_vendor realtek
    setprop persist.log.tag.bluetooth_support 1
    chown bluetooth net_bt_admin /dev/ttyS1
    chmod 0660 /dev/ttyS1
    chown bluetooth net_bt_admin /sys/class/rfkill/rfkill0/state
    chmod 0660 /sys/class/rfkill/rfkill0/state
    insmod /vendor/lib/modules/rtl_btlpm.ko assert_level=1
    chown bluetooth net_bt_admin /proc/bluetooth/sleep/lpm
    chown bluetooth net_bt_admin /proc/bluetooth/sleep/btwrite
    chown bluetooth net_bt_admin /proc/bluetooth/sleep/btwake
    chmod 0660 /proc/bluetooth/sleep/lpm
    chmod 0660 /proc/bluetooth/sleep/btwrite
    chmod 0660 /proc/bluetooth/sleep/btwake
    write /dev/kmsg RG38_BT_INTERNAL_REALTEK_UART_TTYS1_CONFIGURED

# Restore cursor support after Android has finished starting.
service joyMouse /vendor/bin/rg34xx-joymouse
    class late_start
    user root
    group root system input uhid
    seclabel u:r:shell:s0
    priority -10
    disabled

# Trim idle BOOT_COMPLETED broadcast receivers once startup settles (~60 MB saved).
service rg34xx-boot-trim /system/bin/sh /vendor/bin/rg34xx-boot-trim.sh
    class late_start
    user root
    group root system
    seclabel u:r:shell:s0
    disabled
    oneshot

# Framework ashmem allocator required by OMX native-buffer setup and Codec2 (merged from upstream V48).
# The system service binary and framework VINTF declaration already exist.
service rg34xx-hidl-memory /system/bin/hw/android.hidl.allocator@1.0-service
    class hal
    user system
    group system
    interface android.hidl.allocator@1.0::IAllocator ashmem
    seclabel u:r:hal_allocator_default:s0
    disabled

# Event-driven Lid Sleep Power Manager (Option 1: Instant Deep Doze + Radio Cut + 480MHz clamp)
service rg34xx-lid-sleep /system/bin/sh /vendor/bin/rg34xx-lid-sleep.sh
    class late_start
    user root
    group root system input wifi bluetooth net_admin
    seclabel u:r:shell:s0
    disabled

on property:sys.boot_completed=1
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor schedutil
    write /sys/devices/system/cpu/cpufreq/policy0/schedutil/up_rate_limit_us 1000
    write /sys/devices/system/cpu/cpufreq/policy0/schedutil/down_rate_limit_us 10000
    start rg34xx-hidl-memory
    start joyMouse
    start rg34xx-lid-sleep
    start rg34xx-boot-trim
EOF
chown 0:0 "$V/etc/init/hw/init.sun50iw9p1.rc"
chmod 0644 "$V/etc/init/hw/init.sun50iw9p1.rc"
set_selinux "u:object_r:vendor_configs_file:s0" "$V/etc/init/hw/init.sun50iw9p1.rc"

# 3.3 Create /vendor/bin/rg34xx-boot-trim.sh and /vendor/bin/rg34xx-lid-sleep.sh
cat > "$V/bin/rg34xx-boot-trim.sh" << 'EOF'
#!/system/bin/sh
[ "$(getprop persist.andr36oid.boot_trim)" != 0 ] || exit 0
[ ! -d /dev/.rg34xx-boot-trim-done ] || exit 0
sleep 45
[ "$(getprop init.svc.zygote)" = running ] || exit 0
if timeout -k 1 3 /system/bin/cmd activity kill-all; then
    mkdir /dev/.rg34xx-boot-trim-done 2>/dev/null || :
    log -t RG45_TRIM "Post-boot idle app trim completed"
fi
exit 0
EOF
chown 0:2000 "$V/bin/rg34xx-boot-trim.sh"
chmod 0755 "$V/bin/rg34xx-boot-trim.sh"
set_selinux "u:object_r:vendor_file:s0" "$V/bin/rg34xx-boot-trim.sh"

cat > "$V/bin/rg34xx-lid-sleep.sh" << 'EOF'
#!/system/bin/sh
# RG34XX SP Ultra-Low-Power Lid Sleep Manager (Option 1)
# Listens exclusively on the AXP2202 PMIC input device (axp2202-pek / axp2101-pek)
# for Hall-sensor lid-close (KEY_INSERT / 0x006e) and lid-open (KEY_DELETE / 0x006f).
export PATH=/system/bin:/vendor/bin
say() { log -t RG45_SLEEP "$*"; }

# Locate the AXP PMU powerkey/hall-sensor input device node
pek_dev=
attempt=0
while [ "$attempt" -lt 30 ]; do
    for sysnode in /sys/class/input/event*; do
        [ -r "$sysnode/device/name" ] || continue
        name="$(cat "$sysnode/device/name" 2>/dev/null)"
        case "$name" in
            *pek*|*axp*)
                ev="${sysnode##*/}"
                if [ -c "/dev/input/$ev" ]; then
                    pek_dev="/dev/input/$ev"
                    break 2
                fi
                ;;
        esac
    done
    attempt=$((attempt + 1))
    sleep 1
done

if [ -z "$pek_dev" ]; then
    say "AXP PMIC input device not found; lid sleep manager exiting"
    exit 0
fi
say "Monitoring lid Hall sensor on $pek_dev"

# Configure fast Deep Doze constants & disable background scanning while radios are off
settings put global wifi_scan_always_enabled 0 >/dev/null 2>&1
settings put global ble_scan_always_enabled 0 >/dev/null 2>&1
settings put global wifi_sleep_policy 0 >/dev/null 2>&1
settings put global device_idle_constants "inactive_to=5000,sensing_to=0,locating_to=0,location_accuracy=20.0,motion_inactive_to=0,idle_after_inactive_to=0,idle_pending_to=30000,max_idle_pending_to=60000,idle_pending_factor=2.0,idle_to=3600000,max_idle_to=21600000,idle_factor=2.0,min_time_to_alarm=3600000,max_temp_app_whitelist_duration=10000" >/dev/null 2>&1

enter_deep_sleep() {
    [ -f /dev/.rg34xx_lid_closed ] && return 0
    touch /dev/.rg34xx_lid_closed

    # Save current max CPU freq & clamp CPU to lowest OPP (480 MHz) + single core while lid is shut
    if [ -r /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq ]; then
        cur_max="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
        [ -n "$cur_max" ] && [ "$cur_max" -gt 480000 ] 2>/dev/null && printf '%s\n' "$cur_max" > /dev/.rg34xx_saved_max_freq
        printf '480000\n' > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
    fi
    printf '0\n' > /dev/cpuset/top-app/cpus 2>/dev/null
    printf '0\n' > /dev/cpuset/foreground/cpus 2>/dev/null
    printf '0\n' > /dev/cpuset/system-background/cpus 2>/dev/null
    printf '0\n' > /dev/cpuset/background/cpus 2>/dev/null

    # Cut Wi-Fi (powers down axp2202-cldo4 3.3V rail) and Bluetooth if currently enabled,
    # then force Android into Deep Doze so kernel enters ARM PSCI universal-standby (mem).
    (
        wifi_state="$(settings get global wifi_on 2>/dev/null)"
        if [ "$wifi_state" = 1 ] || [ "$wifi_state" = 2 ]; then
            touch /dev/.rg34xx_restore_wifi
            svc wifi disable >/dev/null 2>&1
            ip link set wlan0 down >/dev/null 2>&1
        fi
        bt_state="$(settings get global bluetooth_on 2>/dev/null)"
        if [ "$bt_state" = 1 ]; then
            touch /dev/.rg34xx_restore_bt
            svc bluetooth disable >/dev/null 2>&1
        fi
        cmd deviceidle force-idle deep >/dev/null 2>&1
        say "Lid closed: radios powered down, CPU clamped to 480 MHz, Deep Doze active"
    ) &
}

exit_deep_sleep() {
    [ -f /dev/.rg34xx_lid_closed ] || return 0
    rm -f /dev/.rg34xx_lid_closed

    # 1. Immediate synchronous sysfs restore (<2ms) for zero-lag wake
    saved_max=1512000
    if [ -r /dev/.rg34xx_saved_max_freq ]; then
        saved_max="$(cat /dev/.rg34xx_saved_max_freq 2>/dev/null)"
        rm -f /dev/.rg34xx_saved_max_freq
    fi
    [ -z "$saved_max" ] && saved_max=1512000
    printf '%s\n' "$saved_max" > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null
    printf '0-3\n' > /dev/cpuset/top-app/cpus 2>/dev/null
    printf '0-3\n' > /dev/cpuset/foreground/cpus 2>/dev/null
    printf '0-1\n' > /dev/cpuset/system-background/cpus 2>/dev/null
    printf '0\n' > /dev/cpuset/background/cpus 2>/dev/null

    # 2. Asynchronous Doze exit and radio restoration in background
    (
        cmd deviceidle unforce >/dev/null 2>&1
        if [ -f /dev/.rg34xx_restore_wifi ]; then
            rm -f /dev/.rg34xx_restore_wifi
            ip link set wlan0 up >/dev/null 2>&1
            svc wifi enable >/dev/null 2>&1
        fi
        if [ -f /dev/.rg34xx_restore_bt ]; then
            rm -f /dev/.rg34xx_restore_bt
            svc bluetooth enable >/dev/null 2>&1
        fi
        say "Lid opened: CPU/cpusets restored ($saved_max kHz), Doze exited, radios restored"
    ) &
}

# Block on the single AXP PMIC input device (0% CPU during gameplay)
getevent -q "$pek_dev" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *"0001 006e 00000001"*)
            enter_deep_sleep
            ;;
        *"0001 006f 00000001"*|*"0001 0074 00000001"*)
            exit_deep_sleep
            ;;
    esac
done
exit 0
EOF
chown 0:2000 "$V/bin/rg34xx-lid-sleep.sh"
chmod 0755 "$V/bin/rg34xx-lid-sleep.sh"
set_selinux "u:object_r:vendor_file:s0" "$V/bin/rg34xx-lid-sleep.sh"

# 3.4 Remove duplicate APKs in /vendor/etc/rg34xx/ (keep host-adbkey.pub)
rm -f "$V/etc/rg34xx/Daijisho.apk" \
      "$V/etc/rg34xx/Andr36oidLauncher.apk" \
      "$V/etc/rg34xx/GamepadKeyboard.apk"

# 3.5 Update /vendor/bin/rg34xx-default-home.sh and /vendor/etc/init/rg34xx-default-home.rc for Option A (Andr36oidLauncher)
cat > "$V/bin/rg34xx-default-home.sh" << 'EOF'
#!/system/bin/sh
marker=/data/local/tmp/rg34xx-home-v45.configured
component=org.andr36oid.launcher/games.indiegesindel.sproutlauncher.MainActivity
say() { log -t RG45_HOME "$*"; }
if [ -f "$marker" ]; then
    exit 0
fi
attempt=0
while [ "$attempt" -lt 60 ]; do
    path="$(cmd package path org.andr36oid.launcher 2>/dev/null)"
    case "$path" in package:*) break;; esac
    attempt=$((attempt + 1))
    sleep 1
done
if cmd package set-home-activity --user 0 "$component" >/dev/null 2>&1; then
    am start --user 0 -n "$component" -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1
    printf '%s\n' "$component" > "$marker"
    say "Default home configured: $component"
fi
exit 0
EOF
chown 0:0 "$V/bin/rg34xx-default-home.sh"
chmod 0755 "$V/bin/rg34xx-default-home.sh"
set_selinux "u:object_r:vendor_file:s0" "$V/bin/rg34xx-default-home.sh"

cat > "$V/etc/init/rg34xx-default-home.rc" << 'EOF'
service rg34xx-default-home /system/bin/sh /vendor/bin/rg34xx-default-home.sh
    class late_start
    disabled
    oneshot
    user root
    group root system
    seclabel u:r:shell:s0

on boot
    start rg34xx-default-home
EOF
chown 0:0 "$V/etc/init/rg34xx-default-home.rc"
chmod 0644 "$V/etc/init/rg34xx-default-home.rc"
set_selinux "u:object_r:vendor_file:s0" "$V/etc/init/rg34xx-default-home.rc"

# 3.6 Optimize /vendor/etc/init/rg34xx-owner-setup.rc and scripts (remove power-usb-report & cpu-report loops)
rm -f "$V/bin/rg34xx-power-usb-report.sh" "$V/bin/rg34xx-cpu-report.sh"

cat > "$V/etc/init/rg34xx-owner-setup.rc" << 'EOF'
service rg34xx-owner-setup /vendor/bin/rg34xx-owner-setup.sh
    class late_start
    user root
    group root system log
    seclabel u:r:shell:s0
    disabled
    oneshot

service rg34xx-usb-debug /vendor/bin/rg34xx-usb-debug.sh
    class late_start
    user root
    group root system log
    seclabel u:r:shell:s0
    disabled
    oneshot

service rg34xx-hardware-v27 /vendor/bin/rg34xx-hardware-v27.sh
    class core
    user root
    group root system wifi log
    seclabel u:r:shell:s0
    disabled
    oneshot

on post-fs-data
    start rg34xx-hardware-v27

on boot
    start rg34xx-owner-setup
    start rg34xx-usb-debug

on property:vendor.rg34xx.setup.ready=1
    start rg34xx-usb-debug
EOF
chown 0:0 "$V/etc/init/rg34xx-owner-setup.rc"
chmod 0644 "$V/etc/init/rg34xx-owner-setup.rc"
set_selinux "u:object_r:vendor_file:s0" "$V/etc/init/rg34xx-owner-setup.rc"

cat > "$V/bin/rg34xx-owner-setup.sh" << 'EOF'
#!/system/bin/sh
fn_marker=/data/local/tmp/rg34xx-fn-v26.configured
pwr_marker=/data/local/tmp/rg34xx-power-v27.configured
say() { log -p i -t RG45_SETUP "$*"; }

# Fast path on subsequent boots once setup is already persisted
if [ "$(getprop persist.andr36oid.setup_done)" = 1 ] && [ -f "$fn_marker" ] && [ -f "$pwr_marker" ]; then
    [ -z "$(getprop persist.sys.fn_hotkeys)" ] && setprop persist.sys.fn_hotkeys 1
    setprop vendor.rg34xx.setup.ready 1
    exit 0
fi

attempt=0
while [ "$attempt" -lt 60 ]; do
    package="$(timeout 10 cmd package path android 2>/dev/null)"
    case "$package" in package:*) break;; esac
    attempt=$((attempt+1)); sleep 2
done
[ "$attempt" -ge 60 ] && exit 1

attempt=0
ready=0
while [ "$attempt" -lt 12 ]; do
    attempt=$((attempt+1))
    global="$(timeout 10 settings get global device_provisioned 2>/dev/null)"
    user="$(timeout 10 settings --user 0 get secure user_setup_complete 2>/dev/null)"
    [ "$global" != 1 ] && timeout 10 settings put global device_provisioned 1
    [ "$user" != 1 ] && timeout 10 settings --user 0 put secure user_setup_complete 1
    global="$(timeout 10 settings get global device_provisioned 2>/dev/null)"
    user="$(timeout 10 settings --user 0 get secure user_setup_complete 2>/dev/null)"
    if [ "$global" = 1 ] && [ "$user" = 1 ]; then ready=1; break; fi
    sleep 2
done
[ "$ready" != 1 ] && exit 2
setprop persist.andr36oid.setup_done 1

if [ ! -f "$fn_marker" ]; then
    if timeout 10 settings put global andr36oid_fn_standin scan:312; then
        [ "$(timeout 10 settings get global andr36oid_fn_standin 2>/dev/null)" = scan:312 ] && printf 'scan:312\n' > "$fn_marker"
    fi
fi
[ -z "$(getprop persist.sys.fn_hotkeys)" ] && setprop persist.sys.fn_hotkeys 1

if [ ! -f "$pwr_marker" ]; then
    if timeout 10 settings put global power_button_long_press 1 &&
       [ "$(timeout 10 settings get global power_button_long_press)" = 1 ]; then
        touch "$pwr_marker"
    fi
fi
setprop vendor.rg34xx.setup.ready 1
say "Owner setup complete"
exit 0
EOF
chown 0:0 "$V/bin/rg34xx-owner-setup.sh"
chmod 0755 "$V/bin/rg34xx-owner-setup.sh"
set_selinux "u:object_r:vendor_file:s0" "$V/bin/rg34xx-owner-setup.sh"

cat > "$V/bin/rg34xx-hardware-v27.sh" << 'EOF'
#!/system/bin/sh
say() { log -p i -t RG45_HW "$*"; }
if ! grep -q '^8821cs ' /proc/modules; then
    insmod /vendor/lib/modules/8821cs.ko ifname=wlan0 if2name=p2p0 >/dev/null 2>&1
    say "8821cs load result=$?"
fi
setprop wifi.interface wlan0
attempt=0
while [ ! -d /sys/class/net/wlan0 ] && [ "$attempt" -lt 15 ]; do
    attempt=$((attempt+1)); sleep 1
done
if [ -d /sys/class/net/wlan0 ]; then
    setprop wlan.driver.status ok
    say "Stock wlan0 interface ready"
fi
exit 0
EOF
chown 0:0 "$V/bin/rg34xx-hardware-v27.sh"
chmod 0755 "$V/bin/rg34xx-hardware-v27.sh"
set_selinux "u:object_r:vendor_file:s0" "$V/bin/rg34xx-hardware-v27.sh"

# 3.7 Move only the crashing camera/ril/boringssl .rc files out of /vendor/etc/init/
# IMPORTANT: Keep android.hardware.power-service-aw.rc.disabled, android.hardware.wifi@1.0-service-lazy.rc.disabled,
# init.wlan.common.rc.disabled, android.hardware.bluetooth@1.0-service.rc.disabled, init.bluetooth.common.rc.disabled,
# and android.hardware.lights-service.rc.disabled in /vendor/etc/init/ because Android's init loads them for
# IPower/default, Wi-Fi, Bluetooth, and Lights!
for rc in \
    android.hardware.camera.provider@2.4-external-service.rc.disabled \
    android.hardware.security.keymint-service.rc \
    rild.rc.disabled \
    radio_monitor.rc.disabled \
    env.librild.rc.disabled \
    boringssl_self_test.rc
do
    if [ -f "$V/etc/init/$rc" ]; then
        mv -f "$V/etc/init/$rc" "$V/etc/rg34xx-disabled-init/"
    fi
done

# 3.8 Keep all original /vendor/etc/permissions/*.xml (including android.hardware.wifi.direct.xml required
# by WifiDisplayAdapter at BootPhase_520), and only remove camera/backup XMLs.
for perm in \
    android.hardware.camera.external.xml \
    android.hardware.camera.flash-autofocus.xml \
    android.hardware.camera.front.xml \
    id.hardware.camera.xml \
    android.software.backup.xml
do
    if [ -f "$V/etc/permissions/$perm" ]; then
        mv -f "$V/etc/permissions/$perm" "$V/etc/rg34xx-disabled-features/$perm"
    fi
done

cat > "$V/etc/permissions/gameconsole_unavailable_features.xml" << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <unavailable-feature name="android.software.backup" />
    <unavailable-feature name="android.software.print" />
    <unavailable-feature name="android.hardware.camera" />
    <unavailable-feature name="android.hardware.camera.any" />
    <unavailable-feature name="android.software.picture_in_picture" />
</permissions>
EOF
chown 0:0 "$V/etc/permissions/gameconsole_unavailable_features.xml"
chmod 0644 "$V/etc/permissions/gameconsole_unavailable_features.xml"
set_selinux "u:object_r:vendor_configs_file:s0" "$V/etc/permissions/gameconsole_unavailable_features.xml"


echo "[4/6] Optimizing SYSTEM partition..."
S="$MNT/system/system"

# 4.1 Create /system/etc/init/hw/init.zygote64.rc & update init.zygote64_32.rc for 64-bit-only Zygote
cat > "$S/etc/init/hw/init.zygote64.rc" << 'EOF'
service zygote /system/bin/app_process64 -Xzygote /system/bin --zygote --start-system-server
    class main
    priority -20
    user root
    group root readproc reserved_disk
    socket zygote stream 660 root system
    socket usap_pool_primary stream 660 root system
    onrestart exec_background - system system -- /system/bin/vdc volume abort_fuse
    onrestart write /sys/power/state on
    onrestart restart audioserver
    onrestart restart cameraserver
    onrestart restart media
    onrestart restart netd
    onrestart restart wificond
    task_profiles ProcessCapacityHigh MaxPerformance
EOF
chown 0:0 "$S/etc/init/hw/init.zygote64.rc"
chmod 0644 "$S/etc/init/hw/init.zygote64.rc"
set_selinux "u:object_r:system_file:s0" "$S/etc/init/hw/init.zygote64.rc"

cp -f "$S/etc/init/hw/init.zygote64.rc" "$S/etc/init/hw/init.zygote64_32.rc"
chown 0:0 "$S/etc/init/hw/init.zygote64_32.rc"
chmod 0644 "$S/etc/init/hw/init.zygote64_32.rc"
set_selinux "u:object_r:system_file:s0" "$S/etc/init/hw/init.zygote64_32.rc"

# 4.2 Update /system/build.prop for 64-bit-only ABI & performance props
sed -i \
    -e 's/^ro\.product\.cpu\.abilist=.*/ro.product.cpu.abilist=arm64-v8a/' \
    -e 's/^ro\.product\.cpu\.abilist32=.*/ro.product.cpu.abilist32=/' \
    -e 's/^ro\.product\.cpu\.abilist64=.*/ro.product.cpu.abilist64=arm64-v8a/' \
    "$S/build.prop"

cat >> "$S/build.prop" << 'EOF'

# v45 Performance-First 64-bit Configuration
ro.zygote=zygote64
ro.surface_flinger.supports_background_blur=0
disable_blurs=true
ro.config.webview_zygote_lazy=true
EOF
chown 0:0 "$S/build.prop"
chmod 0600 "$S/build.prop"
set_selinux "u:object_r:system_file:s0" "$S/build.prop"

# 4.3 Remove userdebug & unneeded system init services from /system/etc/init/
for rc in \
    incidentd.rc \
    perfetto.rc \
    traced_perf.rc \
    heapprofd.rc \
    iorapd.rc \
    atrace.rc \
    atrace_userdebug.rc \
    bootstat.rc \
    bootstat-debug.rc \
    dumpstate.rc \
    racoon.rc \
    mdnsd.rc \
    gsid.rc \
    lpdumpd.rc \
    uncrypt.rc \
    recovery-persist.rc \
    lineage-updates.rc \
    lineage-ssh.rc \
    lineage-iosched.rc \
    andr36oid-bioscheck.rc \
    andr36oid-apkinstall.rc
do
    rm -f "$S/etc/init/$rc"
done

# 4.4 Debloat /system/app (Remove Daijishou, R36S/Rockchip-only apps, and unused extras)
for app in \
    Daijishou \
    RgbLights \
    StatusLight \
    BlackFrameInsertion \
    DeepSleep \
    EmmcTool \
    CpuOverclock \
    KernelTweaks \
    StickCalibration \
    Andr36oidControllers \
    TouchMapper \
    SmoothnessTest \
    Andr36oidPlayTime \
    SaveBackup \
    CardCheck \
    ProblemReport \
    BiosCheck \
    Andr36oidGuide \
    Andr36oidCredits \
    ConsoleLook \
    ApkInstall \
    BluetoothMidiService \
    CtsShimPrebuilt \
    WallpaperBackup \
    PacProcessor \
    EthernetSettings
do
    rm -rf "$S/app/$app"
done

# 4.5 Debloat /system/priv-app and /system/system_ext/priv-app
for privapp in \
    CtsShimPrivPrebuilt \
    VpnDialogs
do
    rm -rf "$S/priv-app/$privapp"
done

for extapp in \
    Gallery2 \
    LineageSetupWizard \
    ThemePicker \
    WallpaperCropper
do
    rm -rf "$S/system_ext/priv-app/$extapp"
done


echo "[5/6] Optimizing PRODUCT partition..."
P="$MNT/product"

# 5.1 Update /product/build.prop
sed -i \
    -e 's/^ro\.andr36oid\.power_menu_stats=.*/ro.andr36oid.power_menu_stats=false/' \
    -e 's/^ro\.andr36oid\.version=.*/ro.andr36oid.version=v45-perf-64bit/' \
    "$P/build.prop"

cat >> "$P/build.prop" << 'EOF'
persist.sys.power_menu_stats=0
EOF
chown 0:0 "$P/build.prop"
chmod 0600 "$P/build.prop"
set_selinux "u:object_r:system_file:s0" "$P/build.prop"

# 5.2 Remove SettingsIntelligence, Wallpapers, ThemesStub, and 32-bit WebView oat
rm -rf "$P/priv-app/SettingsIntelligence" \
       "$P/app/Andr36oidWallpapers" \
       "$P/app/LineageThemesStub" \
       "$P/app/ThoriumWebView/oat/arm"

# 5.3 Remove all 78 RRO overlay APKs in /product/overlay/
find "$P/overlay" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

echo "=== Partition Free Space Summary After Optimization ==="
df -h "$MNT/system" "$MNT/vendor" "$MNT/product"

echo "[6/6] Unmounting and running e2fsck verification..."
sync
umount "$MNT/system"
umount "$MNT/vendor"
umount "$MNT/product"
trap - EXIT

e2fsck -f -y "$OUT_DIR/RG34XXSP-v45-system.img" || true
e2fsck -f -y "$OUT_DIR/RG34XXSP-v45-vendor.img" || true
e2fsck -f -y "$OUT_DIR/RG34XXSP-v45-product.img" || true

e2fsck -f -n "$OUT_DIR/RG34XXSP-v45-system.img"
e2fsck -f -n "$OUT_DIR/RG34XXSP-v45-vendor.img"
e2fsck -f -n "$OUT_DIR/RG34XXSP-v45-product.img"

echo "SUCCESS: All three optimized partitions (system, vendor, product) built and verified!"
