#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMG="$BASE_DIR/releases/v45-perf-partitions/RG34XXSP-v45-vendor.img"
MNT="/tmp/rg34xx_vendor_patch"

mkdir -p "$MNT"
umount "$MNT" 2>/dev/null || true
mount -o loop,rw "$IMG" "$MNT"
trap 'sync; umount "$MNT" 2>/dev/null || true' EXIT

# 1. Remove older standalone rg34xx-hidl-memory-fix.rc if present so there is no duplicate service definition
rm -f "$MNT/etc/init/rg34xx-hidl-memory-fix.rc"

# 2. Disable crash-looping vendor.keymint-default (missing AParcel_markSensitive symbol on Android 11)
mkdir -p "$MNT/etc/init/disabled-rc"
if [ -f "$MNT/etc/init/android.hardware.security.keymint-service.rc" ]; then
    mv -f "$MNT/etc/init/android.hardware.security.keymint-service.rc" "$MNT/etc/init/disabled-rc/"
fi

# 3. Merge upstream V48 rg34xx-hidl-memory (with HIDL interface declaration + post-fs-data & boot_completed triggers),
#    wake_lock (prevent un-wakeable H700 mem suspend), and persistent ADB TCP 5555 into init.sun50iw9p1.rc
python3 - "$MNT" << 'PYEOF'
import os, sys

mnt = sys.argv[1]
rc_path = os.path.join(mnt, "etc/init/hw/init.sun50iw9p1.rc")
with open(rc_path, "r", encoding="utf-8") as f:
    txt = f.read()

# Ensure wake_lock + ADB TCP 5555 in on boot
boot_add = (
    "    # Prevent Allwinner H700 un-wakeable mem suspend while keeping screen-off + 480MHz + radio-cut sleep\n"
    "    write /sys/power/wake_lock rg34xx_no_mem_suspend\n"
    "    # Keep wireless ADB TCP port 5555 enabled across reboots\n"
    "    setprop service.adb.tcp.port 5555\n"
)
if "rg34xx_no_mem_suspend" not in txt:
    target = "    write /sys/kernel/debug/tracing/tracing_on 0\n"
    assert target in txt, "Target tracing_on line not found in init.sun50iw9p1.rc"
    txt = txt.replace(target, target + boot_add, 1)

# Ensure upstream V48 rg34xx-hidl-memory service block + post-fs-data & boot_completed starts
v48_block = (
    "\n# Framework ashmem allocator required by OMX native-buffer setup and Codec2 (merged from upstream V48).\n"
    "# The system service binary and framework VINTF declaration already exist.\n"
    "service rg34xx-hidl-memory /system/bin/hw/android.hidl.allocator@1.0-service\n"
    "    class hal\n"
    "    user system\n"
    "    group system\n"
    "    interface android.hidl.allocator@1.0::IAllocator ashmem\n"
    "    seclabel u:r:hal_allocator_default:s0\n"
    "    disabled\n"
    "\non post-fs-data\n"
    "    start rg34xx-hidl-memory\n"
    "\non property:sys.boot_completed=1\n"
    "    start rg34xx-hidl-memory\n"
)
if "interface android.hidl.allocator@1.0::IAllocator ashmem" not in txt:
    txt = txt.rstrip() + "\n" + v48_block

with open(rc_path, "w", encoding="utf-8", newline="\n") as f:
    f.write(txt)

# Verify SELinux security.selinux xattr
ctx = "u:object_r:vendor_configs_file:s0"
os.setxattr(rc_path, b"security.selinux", ctx.encode("ascii") + b"\x00", follow_symlinks=False)
val = os.getxattr(rc_path, b"security.selinux", follow_symlinks=False)
print(f"SELinux xattr verified: init.sun50iw9p1.rc -> {val}")
PYEOF

echo "=== Verifying merged init.sun50iw9p1.rc ==="
tail -n 25 "$MNT/etc/init/hw/init.sun50iw9p1.rc"
ls -la "$MNT/etc/init/disabled-rc/android.hardware.security.keymint-service.rc"

sync
umount "$MNT"
trap - EXIT

echo "=== Running e2fsck verification ==="
e2fsck -f -p "$IMG" || true
e2fsck -f -n "$IMG"
echo "PATCH_V48_MERGED_SUCCESS"
