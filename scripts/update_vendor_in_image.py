import hashlib
import json
import os
import subprocess
import sys

base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
v45_parts = os.path.join(base_dir, "releases", "v45-perf-partitions")
out_img = os.path.join(base_dir, "releases", "RG34XXSP-Andr36oid-Android11-v45-perf-complete.img")

sys_img = os.path.join(v45_parts, "RG34XXSP-v45-system.img")
ven_img = os.path.join(v45_parts, "RG34XXSP-v45-vendor.img")
prd_img = os.path.join(v45_parts, "RG34XXSP-v45-product.img")

def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(16 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

print("Updating system, vendor, and product partitions in-place in complete image...")
with open(out_img, "r+b") as img:
    for offset, length, path in [
        (289406976, 2147483648, sys_img),
        (2436890624, 536870912, ven_img),
        (2973761536, 536870912, prd_img),
    ]:
        assert os.path.getsize(path) == length
        img.seek(offset)
        with open(path, "rb") as src:
            while True:
                buf = src.read(16 * 1024 * 1024)
                if not buf:
                    break
                img.write(buf)

print("Computing updated SHA-256 hashes...")
sys_sha = file_sha256(sys_img)
ven_sha = file_sha256(ven_img)
prd_sha = file_sha256(prd_img)
img_sha = file_sha256(out_img)

manifest_path = os.path.join(v45_parts, "v45-manifest.json")
with open(manifest_path, "r", encoding="utf-8-sig") as mf:
    manifest = json.load(mf)

manifest["system_sha256"] = sys_sha
manifest["vendor_sha256"] = ven_sha
manifest["product_sha256"] = prd_sha
manifest["uncompressed_img_sha256"] = img_sha

with open(manifest_path, "w", encoding="utf-8") as mf:
    json.dump(manifest, mf, indent=2)

print(f"Updated uncompressed SHA-256: {img_sha}")
subprocess.check_call([sys.executable, os.path.join(base_dir, "scripts", "compress_and_verify_image.py")])
