#!/usr/bin/env python3
"""Parse the partition table from the full disk image backup (gzip stream)."""
import gzip
import struct
import sys

IMG = r"D:\Repo\lg6151m\backup\mmcblk0.img.gz"
SECTOR = 512


def read_at(f, offset, size):
    f.seek(offset)
    return f.read(size)


def main():
    f = gzip.open(IMG, "rb")  # random access on gzip via seek works (slow but ok for small reads)
    mbr = read_at(f, 0, SECTOR)
    print("MBR signature:", mbr[510:512].hex())
    # GPT check at LBA1
    gpt = read_at(f, SECTOR, SECTOR)
    print("LBA1 signature:", gpt[:8])
    if gpt[:8] == b"EFI PART":
        hdr = gpt
        part_lba = struct.unpack("<Q", hdr[72:80])[0]
        num_parts = struct.unpack("<I", hdr[80:84])[0]
        part_size = struct.unpack("<I", hdr[84:88])[0]
        print(f"GPT: entries={num_parts} at LBA {part_lba}, entry size={part_size}")
        table = read_at(f, part_lba * SECTOR, num_parts * part_size)
        print(f"{'#':>3} {'start LBA':>12} {'end LBA':>12} {'size(MiB)':>10}  name")
        for i in range(num_parts):
            e = table[i * part_size:(i + 1) * part_size]
            if e[:16] == b"\x00" * 16:
                continue
            first, last = struct.unpack("<QQ", e[32:48])
            name = e[56:128].decode("utf-16-le").rstrip("\x00")
            size_mib = (last - first + 1) * SECTOR / 1048576
            print(f"{i+1:>3} {first:>12} {last:>12} {size_mib:>10.1f}  {name}")
    else:
        print("no GPT — parse MBR partitions")
        for i in range(4):
            e = mbr[446 + i * 16:446 + (i + 1) * 16]
            if e[4] == 0:
                continue
            lba, nsec = struct.unpack("<II", e[8:16])
            print(f"part{i+1}: type={e[4]:#x} start={lba} sectors={nsec} size={nsec*SECTOR/1048576:.1f}MiB")
    f.close()


if __name__ == "__main__":
    main()
