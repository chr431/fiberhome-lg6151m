#!/usr/bin/env python3
"""Parse the partition table of a full-disk dump (gzip random access).
Usage: python parse_gpt.py [image.img.gz]
Output: all GPT partitions with names -- LG6151M layout is a fully mirrored
A/B scheme (boot/rootfs/lk/tee/modem images x2)."""
import gzip
import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "../backup/mmcblk0.img.gz"
SECTOR = 512


def main():
    f = gzip.open(IMG, "rb")
    mbr = f.read(SECTOR)
    print("MBR signature:", mbr[510:512].hex())
    gpt = f.read(SECTOR)
    print("LBA1 signature:", gpt[:8])
    if gpt[:8] != b"EFI PART":
        print("no GPT")
        return
    part_lba = struct.unpack("<Q", gpt[72:80])[0]
    num_parts = struct.unpack("<I", gpt[80:84])[0]
    part_size = struct.unpack("<I", gpt[84:88])[0]
    print(f"GPT: entries={num_parts} at LBA {part_lba}, entry size={part_size}")
    f.seek(part_lba * SECTOR)
    table = f.read(num_parts * part_size)
    print(f"{'#':>3} {'start LBA':>12} {'end LBA':>12} {'size(MiB)':>10}  name")
    for i in range(num_parts):
        e = table[i * part_size:(i + 1) * part_size]
        if e[:16] == b"\x00" * 16:
            continue
        first, last = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16-le").rstrip("\x00")
        print(f"{i+1:>3} {first:>12} {last:>12} {(last-first+1)*SECTOR/1048576:>10.1f}  {name}")


if __name__ == "__main__":
    main()
