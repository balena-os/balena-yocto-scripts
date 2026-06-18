#!/usr/bin/env python3
"""Golden regression test for the prepare-image.py image compressor.

Synthesizes tiny MBR and GPT disk images in memory (no committed binaries),
runs the compressor, and asserts the properties image-maker/etcher-sdk actually
depend on:

  - The emitted part plan (gap/partition boundaries + partitionIndex) matches a
    hand-computed golden. This guards the partition parsers (_parse_mbr,
    _parse_gpt, the EBR walk) and plan_parts against silent regressions.
  - Each part's crc/len match its manifest entry, and the part ends with the
    Z_SYNC_FLUSH marker (00 00 ff ff) so parts stay concatenatable.
  - Concatenating the parts + the DEFLATE end marker (03 00) and inflating
    reproduces the original image byte-for-byte. This is the etcher-sdk
    BalenaS3CompressedSource consumption contract, and it is the definitive
    correctness check (part ordering, gap coverage, framing, compression).

Deliberately NOT a byte-exact hash of the compressed output: zlib's compressed
bytes and zLen vary across zlib versions, so a hash golden would flake on a
valid stream. The consumer navigates via the manifest and inflates, so the
invariants above are both stronger (they prove correctness, not sameness) and
version-robust.

Stdlib only; runs in the sandbox with no dependencies:
    python3 tests/test_prepare_image.py
It is also pytest-discoverable outside the sandbox.
"""

import importlib.util
import json
import os
import struct
import tempfile
import unittest
import zlib

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "automation",
    "conversion_scripts",
    "prepare-image.py",
)
_spec = importlib.util.spec_from_file_location("prepare_image", _MODULE_PATH)
prepare_image = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(prepare_image)

SECTOR = 512
SYNC_FLUSH_MARKER = b"\x00\x00\xff\xff"
DEFLATE_END = b"\x03\x00"


def _pattern(size):
    """Deterministic, poorly-compressible filler so parts have real content."""
    return bytes((i * 37 + 11) & 0xFF for i in range(size))


def _zero_ptable(buf, sector_off):
    """Zero the 4-entry (64-byte) MBR/EBR partition table so the filler pattern
    doesn't masquerade as populated (non-zero type) partition slots."""
    buf[sector_off + 446 : sector_off + 446 + 64] = b"\x00" * 64


def _put_entry(buf, sector_off, slot, ptype, lba_start, num_sectors):
    """Write one 16-byte partition-table entry at sector_off's table (offset 446)."""
    base = sector_off + 446 + slot * 16
    buf[base + 4] = ptype
    struct.pack_into("<II", buf, base + 8, lba_start, num_sectors)


def _build_mbr_image():
    """One primary + an extended container holding two logical partitions (EBR chain)."""
    total = 180 * SECTOR
    img = bytearray(_pattern(total))
    ebr1 = 100 * SECTOR                    # first EBR (== extended base)
    ebr2 = 150 * SECTOR
    for sector_off in (0, ebr1, ebr2):
        _zero_ptable(img, sector_off)
    _put_entry(img, 0, 0, 0x83, 34, 20)   # primary P1                 -> index 1
    _put_entry(img, 0, 1, 0x05, 100, 80)  # extended container @ sector 100
    img[510], img[511] = 0x55, 0xAA
    _put_entry(img, ebr1, 0, 0x83, 1, 10)  # logical L1 @ sector 101   -> index 5
    _put_entry(img, ebr1, 1, 0x05, 50, 30)  # link to EBR2 (+50 from base)
    _put_entry(img, ebr2, 0, 0x83, 1, 10)  # logical L2 @ sector 151   -> index 6
    return bytes(img)


# start/end are inclusive byte offsets; partition_index present only on partition parts.
MBR_GOLDEN_PLAN = [
    {"start": 0, "end": 17407},
    {"start": 17408, "end": 27647, "partition_index": 1},
    {"start": 27648, "end": 51711},
    {"start": 51712, "end": 56831, "partition_index": 5},
    {"start": 56832, "end": 77311},
    {"start": 77312, "end": 82431, "partition_index": 6},
    {"start": 82432, "end": 92159},
]


def _build_gpt_image():
    """Protective MBR + GPT (512-byte blocks) with two used entries and empty slots."""
    total = 60 * SECTOR
    img = bytearray(_pattern(total))
    _zero_ptable(img, 0)
    _put_entry(img, 0, 0, 0xEE, 1, (total // SECTOR) - 1)  # protective MBR
    img[510], img[511] = 0x55, 0xAA
    hdr = 1 * SECTOR
    img[hdr : hdr + 8] = b"EFI PART"
    entries_lba, num_entries, entry_size = 2, 4, 128
    struct.pack_into("<QII", img, hdr + 72, entries_lba, num_entries, entry_size)
    table = entries_lba * SECTOR
    # Zero the whole entry array so unused slots read as unused (all-zero type GUID).
    img[table : table + num_entries * entry_size] = b"\x00" * (num_entries * entry_size)

    def put_part(slot, first_lba, last_lba):
        off = table + slot * entry_size
        img[off : off + 16] = b"\x11" * 16  # non-zero type GUID = used slot
        struct.pack_into("<QQ", img, off + 32, first_lba, last_lba)

    put_part(0, 34, 39)  # -> index 1
    put_part(2, 45, 49)  # slot 1 left empty -> this is index 3
    return bytes(img)


GPT_GOLDEN_PLAN = [
    {"start": 0, "end": 17407},
    {"start": 17408, "end": 20479, "partition_index": 1},
    {"start": 20480, "end": 23039},
    {"start": 23040, "end": 25599, "partition_index": 3},
    {"start": 25600, "end": 30719},
]


class PrepareImageGoldenTest(unittest.TestCase):
    def _assert_plan(self, image_bytes, golden_plan):
        import io

        f = io.BytesIO(image_bytes)
        partitions = prepare_image.get_partitions(f)
        plan = prepare_image.plan_parts(partitions, len(image_bytes))
        self.assertEqual(plan, golden_plan)

    def _assert_roundtrip(self, image_bytes, golden_plan):
        with tempfile.TemporaryDirectory() as d:
            img_path = os.path.join(d, "resin.img")
            with open(img_path, "wb") as fh:
                fh.write(image_bytes)

            manifest_path = prepare_image.prepare_raw_image(img_path, d)
            with open(manifest_path) as fh:
                manifest = json.load(fh)

            parts = manifest["resin.img"]["parts"]
            self.assertEqual(len(parts), len(golden_plan))

            blob = b""
            for golden, entry in zip(golden_plan, parts):
                part_path = os.path.join(d, "compressed", entry["filename"])
                with open(part_path, "rb") as pf:
                    raw = pf.read()

                self.assertEqual(len(raw), entry["zLen"])
                self.assertTrue(
                    raw.endswith(SYNC_FLUSH_MARKER),
                    f"{entry['filename']} missing Z_SYNC_FLUSH framing",
                )

                out = zlib.decompress(raw + DEFLATE_END, -zlib.MAX_WBITS)
                self.assertEqual(len(out), entry["len"])
                self.assertEqual(zlib.crc32(out) & 0xFFFFFFFF, entry["crc"])

                if "partition_index" in golden:
                    self.assertEqual(
                        entry.get("partitionIndex"), f"({golden['partition_index']})"
                    )
                else:
                    self.assertNotIn("partitionIndex", entry)

                blob += raw

            whole = zlib.decompress(blob + DEFLATE_END, -zlib.MAX_WBITS)
            self.assertEqual(whole, image_bytes)

    def test_mbr_plan(self):
        self._assert_plan(_build_mbr_image(), MBR_GOLDEN_PLAN)

    def test_mbr_roundtrip(self):
        self._assert_roundtrip(_build_mbr_image(), MBR_GOLDEN_PLAN)

    def test_gpt_plan(self):
        self._assert_plan(_build_gpt_image(), GPT_GOLDEN_PLAN)

    def test_gpt_roundtrip(self):
        self._assert_roundtrip(_build_gpt_image(), GPT_GOLDEN_PLAN)


if __name__ == "__main__":
    unittest.main()
