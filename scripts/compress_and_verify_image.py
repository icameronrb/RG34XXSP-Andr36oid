import concurrent.futures
import gzip
import hashlib
import json
import os
import struct
import zlib

base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
raw_img = os.path.join(base_dir, "releases", "RG34XXSP-Andr36oid-Android11-v45-perf-complete.img")
gz_img = os.path.join(base_dir, "releases", "RG34XXSP-Andr36oid-Android11-v45-perf-complete.img.gz")
v45_parts = os.path.join(base_dir, "releases", "v45-perf-partitions")
sha_file = os.path.join(base_dir, "releases", "RG34XXSP-v45-SHA256SUMS.txt")

def verify_gpt(img_path):
    size = os.path.getsize(img_path)
    with open(img_path, "rb") as f:
        # LBA 1: Primary GPT Header at 512
        f.seek(512)
        hdr = f.read(92)
        sig, rev, hdr_size, hdr_crc, rsvd, my_lba, alt_lba, first_usable, last_usable = struct.unpack("<8sIIIIQQQQ", hdr[:56])
        guid = hdr[56:72]
        part_lba, num_parts, part_entry_size, part_crc = struct.unpack("<QIII", hdr[72:92])
        assert sig == b"EFI PART", f"Bad primary GPT signature: {sig}"
        hdr_zeroed = hdr[:16] + b"\x00\x00\x00\x00" + hdr[20:]
        calc_hdr_crc = zlib.crc32(hdr_zeroed) & 0xFFFFFFFF
        assert calc_hdr_crc == hdr_crc, f"Primary GPT header CRC mismatch: {calc_hdr_crc:#x} != {hdr_crc:#x}"

        f.seek(part_lba * 512)
        ptable = f.read(num_parts * part_entry_size)
        calc_part_crc = zlib.crc32(ptable) & 0xFFFFFFFF
        assert calc_part_crc == part_crc, f"Primary GPT partition table CRC mismatch"

        print(f"Primary GPT verified: {num_parts} entries, backup LBA={alt_lba} (offset {alt_lba*512}, file size={size})")
        for i in range(num_parts):
            entry = ptable[i*part_entry_size:(i+1)*part_entry_size]
            ptype = entry[:16]
            if ptype == b"\x00" * 16:
                continue
            first_lba, last_lba, flags = struct.unpack("<QQQ", entry[32:56])
            name = entry[56:128].decode("utf-16le", errors="ignore").split("\x00")[0]
            p_offset = first_lba * 512
            p_bytes = (last_lba - first_lba + 1) * 512
            print(f"  Partition {i+1}: {name:12s} offset={p_offset:<12d} bytes={p_bytes:<12d} ({p_bytes//(1024*1024)} MiB)")

        # Backup GPT header at alt_lba * 512
        f.seek(alt_lba * 512)
        bhdr = f.read(92)
        bsig = bhdr[:8]
        assert bsig == b"EFI PART", f"Bad backup GPT signature: {bsig}"
        bhdr_crc = struct.unpack("<I", bhdr[16:20])[0]
        bhdr_zeroed = bhdr[:16] + b"\x00\x00\x00\x00" + bhdr[20:]
        assert (zlib.crc32(bhdr_zeroed) & 0xFFFFFFFF) == bhdr_crc, "Backup GPT header CRC mismatch"
        print("Backup GPT header & CRC32 verified!")

def compress_chunk(data):
    return gzip.compress(data, compresslevel=6, mtime=0)

if __name__ == "__main__":
    print("=== [1/3] Verifying GPT Partition Table & Checksums ===")
    verify_gpt(raw_img)

    print(f"=== [2/3] Compressing {os.path.basename(raw_img)} using parallel GZIP streams ===")
    workers = os.cpu_count() or 8
    chunk_size = 16 * 1024 * 1024
    # Pre-compute compressed chunk for 16MB of all-zeros so zero blocks take 0 CPU time!
    zero_chunk = b"\x00" * chunk_size
    zero_gz = compress_chunk(zero_chunk)

    gz_hash = hashlib.sha256()
    raw_hash = hashlib.sha256()
    total_in = os.path.getsize(raw_img)
    written_in = 0
    total_out = 0

    with open(raw_img, "rb") as fin, open(gz_img, "wb") as fout:
        with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as ex:
            while written_in < total_in:
                batch = []
                futures = []
                for _ in range(workers * 2):
                    buf = fin.read(chunk_size)
                    if not buf:
                        break
                    raw_hash.update(buf)
                    written_in += len(buf)
                    if buf == zero_chunk:
                        futures.append(None)
                    else:
                        futures.append(ex.submit(compress_chunk, buf))
                for fut in futures:
                    c = zero_gz if fut is None else fut.result()
                    fout.write(c)
                    gz_hash.update(c)
                    total_out += len(c)
                print(f"  Progress: {written_in * 100 // total_in}% ({written_in // (1024*1024)} / {total_in // (1024*1024)} MiB) -> {total_out // (1024*1024)} MiB gz")

    gz_sha256 = gz_hash.hexdigest()
    raw_sha256 = raw_hash.hexdigest()
    print(f"=== [3/3] Compression Complete ===")
    print(f"Compressed size: {total_out} bytes ({total_out / (1024*1024):.2f} MiB)")
    print(f"Compressed SHA-256: {gz_sha256}")
    print(f"Uncompressed SHA-256: {raw_sha256}")

    manifest_path = os.path.join(v45_parts, "v45-manifest.json")
    with open(manifest_path, "r", encoding="utf-8-sig") as mf:
        manifest = json.load(mf)
    manifest["uncompressed_img_sha256"] = raw_sha256
    manifest["compressed_img_bytes"] = total_out
    manifest["compressed_img_sha256"] = gz_sha256
    with open(manifest_path, "w", encoding="utf-8") as mf:
        json.dump(manifest, mf, indent=2)

    with open(sha_file, "w", encoding="utf-8") as sf:
        sf.write(f"{gz_sha256}  RG34XXSP-Andr36oid-Android11-v45-perf-complete.img.gz\n")
        sf.write(f"{manifest['uncompressed_img_sha256']}  RG34XXSP-Andr36oid-Android11-v45-perf-complete.img\n")
        sf.write(f"{manifest['system_sha256']}  v45-perf-partitions/RG34XXSP-v45-system.img\n")
        sf.write(f"{manifest['vendor_sha256']}  v45-perf-partitions/RG34XXSP-v45-vendor.img\n")
        sf.write(f"{manifest['product_sha256']}  v45-perf-partitions/RG34XXSP-v45-product.img\n")
    print(f"Wrote {sha_file}")
