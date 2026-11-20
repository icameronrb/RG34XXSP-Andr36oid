#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/releases/v45-perf-partitions"
MNT="/tmp/rg34xx_v45_verify"
rm -rf "$MNT"
mkdir -p "$MNT/system" "$MNT/vendor" "$MNT/product"

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

echo "=== [1/5] Verifying SELinux Contexts & Permissions ==="
ls -lZ \
    "$MNT/vendor/build.prop" \
    "$MNT/vendor/etc/init/hw/init.sun50iw9p1.rc" \
    "$MNT/vendor/etc/init/rg34xx-default-home.rc" \
    "$MNT/vendor/etc/init/rg34xx-owner-setup.rc" \
    "$MNT/vendor/bin/rg34xx-boot-trim.sh" \
    "$MNT/vendor/bin/rg34xx-lid-sleep.sh" \
    "$MNT/vendor/bin/rg34xx-default-home.sh" \
    "$MNT/vendor/bin/rg34xx-owner-setup.sh" \
    "$MNT/vendor/bin/rg34xx-hardware-v27.sh" \
    "$MNT/vendor/bin/rg34xx-ram-profile.sh" \
    "$MNT/vendor/etc/vintf/manifest.xml" \
    "$MNT/vendor/etc/permissions/gameconsole_unavailable_features.xml" \
    "$MNT/system/system/build.prop" \
    "$MNT/system/system/etc/init/hw/init.zygote64.rc" \
    "$MNT/system/system/etc/init/hw/init.zygote64_32.rc" \
    "$MNT/product/build.prop"

echo "=== [2/5] Verifying Shell Script Syntax (sh -n) ==="
for shfile in "$MNT/vendor/bin"/rg34xx-*.sh; do
    sh -n "$shfile"
    echo "  PASS sh -n: $(basename "$shfile")"
done

echo "=== [3/5] Verifying XML Syntax (manifest.xml & permissions/*.xml) ==="
python3 -c '
import glob, xml.etree.ElementTree as ET
files = ["/tmp/rg34xx_v45_verify/vendor/etc/vintf/manifest.xml"] + glob.glob("/tmp/rg34xx_v45_verify/vendor/etc/permissions/*.xml")
for f in files:
    ET.parse(f)
print(f"  PASS XML parse: {len(files)} files validated")
'

echo "=== [4/5] Zero-filling unused blocks in system, vendor, and product for optimal gzip compression ==="
for mp in "$MNT/system" "$MNT/vendor" "$MNT/product"; do
    dd if=/dev/zero of="$mp/.zero_fill" bs=4M status=none 2>/dev/null || true
    sync
    rm -f "$mp/.zero_fill"
    sync
done

echo "=== [5/5] Unmounting and running final read-only e2fsck -f -n ==="
umount "$MNT/system"
umount "$MNT/vendor"
umount "$MNT/product"
trap - EXIT

e2fsck -f -n "$OUT_DIR/RG34XXSP-v45-system.img"
e2fsck -f -n "$OUT_DIR/RG34XXSP-v45-vendor.img"
e2fsck -f -n "$OUT_DIR/RG34XXSP-v45-product.img"
echo "ALL VERIFICATION CHECKS PASSED!"
