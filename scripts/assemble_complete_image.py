import gzip
import hashlib
import json
import os

base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
v43_gz = os.path.join(base_dir, "releases", "RG34XXSP-Andr36oid-Android11-v43-complete.img.gz")
v43_parts = os.path.join(base_dir, "releases", "v43-partitions")
v45_parts = os.path.join(base_dir, "releases", "v45-perf-partitions")
out_img = os.path.join(base_dir, "releases", "RG34XXSP-Andr36oid-Android11-v45-perf-complete.img")

sys_img = os.path.join(v45_parts, "RG34XXSP-v45-system.img")
ven_img = os.path.join(v45_parts, "RG34XXSP-v45-vendor.img")
prd_img = os.path.join(v45_parts, "RG34XXSP-v45-product.img")
boot_img = os.path.join(v43_parts, "p4_boot.img")

assert os.path.getsize(sys_img) == 2147483648, "Invalid system.img size"
assert os.path.getsize(ven_img) == 536870912, "Invalid vendor.img size"
assert os.path.getsize(prd_img) == 536870912, "Invalid product.img size"

def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(16 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

print("Computing SHA-256 of v45 partition images...")
boot_sha = file_sha256(boot_img)
sys_sha = file_sha256(sys_img)
ven_sha = file_sha256(ven_img)
prd_sha = file_sha256(prd_img)
print(f"  boot_sha256:    {boot_sha}")
print(f"  system_sha256:  {sys_sha}")
print(f"  vendor_sha256:  {ven_sha}")
print(f"  product_sha256: {prd_sha}")

manifest = {
    "version": 45,
    "variant": "perf-64bit-andr36oidlauncher",
    "boot_sha256": boot_sha,
    "system_sha256": sys_sha,
    "vendor_sha256": ven_sha,
    "product_sha256": prd_sha,
    "system_offset": 289406976,
    "system_bytes": 2147483648,
    "vendor_offset": 2436890624,
    "vendor_bytes": 536870912,
    "product_offset": 2973761536,
    "product_bytes": 536870912,
}
with open(os.path.join(v45_parts, "v45-manifest.json"), "w", encoding="utf-8") as mf:
    json.dump(manifest, mf, indent=2)

# Extract p8_userdata_and_gpt_tail.bin if not already extracted
p8_tail = os.path.join(v43_parts, "p8_userdata_and_gpt_tail.bin")
if not os.path.exists(p8_tail):
    print("Extracting p8_userdata_and_gpt_tail.bin from v43 complete.img.gz...")
    with gzip.open(v43_gz, "rb") as f:
        rem = 3510632448
        while rem > 0:
            chunk = f.read(min(16 * 1024 * 1024, rem))
            if not chunk:
                raise EOFError("Unexpected EOF before p8")
            rem -= len(chunk)
        with open(p8_tail, "wb") as out:
            while True:
                chunk = f.read(16 * 1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
    print(f"Extracted p8_userdata_and_gpt_tail.bin ({os.path.getsize(p8_tail)} bytes)")

segments = [
    (0, 37748736, os.path.join(v43_parts, "p0_header_uboot.bin")),
    (37748736, 134217728, os.path.join(v43_parts, "p1_bootfat.img")),
    (171966464, 33554432, os.path.join(v43_parts, "p2_resources.img")),
    (205520896, 16777216, os.path.join(v43_parts, "p3_env.img")),
    (222298112, 67108864, os.path.join(v43_parts, "p4_boot.img")),
    (289406976, 2147483648, sys_img),
    (2436890624, 536870912, ven_img),
    (2973761536, 536870912, prd_img),
    (3510632448, os.path.getsize(p8_tail), p8_tail),
]

print(f"Assembling {out_img}...")
img_hash = hashlib.sha256()
pos = 0
with open(out_img, "wb") as out:
    for expected_offset, expected_len, path in segments:
        assert pos == expected_offset, f"Offset mismatch at {path}: {pos} != {expected_offset}"
        actual_len = os.path.getsize(path)
        assert actual_len == expected_len, f"Length mismatch at {path}: {actual_len} != {expected_len}"
        print(f"  Writing {os.path.basename(path)} at offset {pos} ({actual_len // (1024*1024)} MiB)...")
        with open(path, "rb") as src:
            while True:
                buf = src.read(16 * 1024 * 1024)
                if not buf:
                    break
                out.write(buf)
                img_hash.update(buf)
                pos += len(buf)

uncompressed_sha256 = img_hash.hexdigest()
print(f"Assembled {out_img} ({pos} bytes)")
print(f"Uncompressed SHA-256: {uncompressed_sha256}")

manifest["uncompressed_img_bytes"] = pos
manifest["uncompressed_img_sha256"] = uncompressed_sha256
with open(os.path.join(v45_parts, "v45-manifest.json"), "w", encoding="utf-8") as mf:
    json.dump(manifest, mf, indent=2)
