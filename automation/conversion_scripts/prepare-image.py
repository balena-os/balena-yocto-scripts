#!/usr/bin/env python3
"""Compress a single balenaOS raw disk image into concatenatable DEFLATE parts.

Port of the ``prepareRawImage`` / ``cacheRawImageParts`` logic from the upstream
balena-img ``prepare.ts`` script, reduced to act on one explicit ``.img`` file
with no path-prefix walking, no S3 upload and no intel-edison handling.

The image is split into "parts" at partition boundaries (with gap parts for the
space between/around partitions). Each part is compressed as a raw DEFLATE stream
terminated by an empty sync block (``00 00 ff ff``) so the parts can be
concatenated, topped with a gzip header and footer, into a single valid gzip
stream. This is the format consumed by etcher-sdk's BalenaS3CompressedSource,
which re-appends the DEFLATE end marker (``03 00``) before inflating.

Outputs, written under the chosen output directory:
  - ``compressed{suffix}/part-N.deflate`` for each part
  - ``image{suffix}.json`` manifest:
        {"resin.img": {"parts": [{filename, crc, len, zLen, partitionIndex?}]}}

Dependencies: Python 3 standard library only (zlib, struct, json, argparse).
"""

import argparse
import json
import os
import struct
import sys
import zlib

SECTOR_SIZE = 512
# MBR partition types that denote an extended (container) partition.
EXTENDED_TYPES = {0x05, 0x0F, 0x85}
GPT_PROTECTIVE_MBR_TYPE = 0xEE
MBR_FIRST_LOGICAL_PARTITION = 5
# Guard against malformed/looping EBR chains.
MAX_LOGICAL_PARTITIONS = 256
# Read size when streaming a part through the compressor.
CHUNK_SIZE = 1 << 20  # 1 MiB
# Empty final DEFLATE block; the consumer appends this before inflating.
DEFLATE_END = b"\x03\x00"


# --- functional core: partition parsing ------------------------------------


def _read_at(f, offset, size):
    f.seek(offset)
    buf = f.read(size)
    if len(buf) != size:
        raise ValueError(f"Short read at offset {offset}: wanted {size}, got {len(buf)}")
    return buf


def _partition(start, size, index):
    """Build a partition record (inclusive end byte) shared by the MBR/GPT parsers."""
    return {"start": start, "end": start + size - 1, "size": size, "index": index}


def _mbr_entries(buf):
    """Return the (slot-order, type != 0) MBR partition entries from a 512B sector.

    Mirrors partitioninfo's ``getPartitionsFromMBRBuf`` which filters out empty
    (type 0) slots while preserving order. Each entry is a dict with the raw
    relative LBA offset and size in sectors plus the partition type byte.
    """
    entries = []
    for i in range(4):
        base = 446 + i * 16
        ptype = buf[base + 4]
        lba_start, num_sectors = struct.unpack_from("<II", buf, base + 8)
        if ptype != 0:
            entries.append(
                {"type": ptype, "lba_start": lba_start, "num_sectors": num_sectors}
            )
    return entries


def _logical_partitions(f, index, offset, extended_base, limit):
    """Walk the EBR chain of an extended partition.

    ``offset`` is the absolute byte offset of the current EBR. ``extended_base``
    is the absolute byte offset of the extended container (the base against which
    next-EBR links are resolved). Mirrors partitioninfo's ``getLogicalPartitions``.
    """
    result = []
    if limit <= 0:
        return result
    for p in _mbr_entries(_read_at(f, offset, SECTOR_SIZE)):
        if p["type"] not in EXTENDED_TYPES:
            start = offset + p["lba_start"] * SECTOR_SIZE
            size = p["num_sectors"] * SECTOR_SIZE
            result.append(_partition(start, size, index))
        else:
            result.extend(
                _logical_partitions(
                    f,
                    index + 1,
                    extended_base + p["lba_start"] * SECTOR_SIZE,
                    extended_base,
                    limit - 1,
                )
            )
            return result
    return result


def _parse_mbr(f):
    """Parse an MBR partition table (primaries + logical, extended excluded)."""
    entries = _mbr_entries(_read_at(f, 0, SECTOR_SIZE))
    partitions = []
    extended = None
    for i, p in enumerate(entries):
        index = i + 1
        if p["type"] in EXTENDED_TYPES:
            extended = p
            continue  # includeExtended: false
        start = p["lba_start"] * SECTOR_SIZE
        size = p["num_sectors"] * SECTOR_SIZE
        partitions.append(_partition(start, size, index))
    if extended is not None:
        extended_base = extended["lba_start"] * SECTOR_SIZE
        partitions.extend(
            _logical_partitions(
                f,
                MBR_FIRST_LOGICAL_PARTITION,
                extended_base,
                extended_base,
                MAX_LOGICAL_PARTITIONS,
            )
        )
    return partitions


def _parse_gpt(f, block_size):
    """Parse a GPT at the given block size. Returns partitions or None on mismatch."""
    header = _read_at(f, block_size, 92)
    if header[:8] != b"EFI PART":
        return None
    entries_lba, num_entries, entry_size = struct.unpack_from("<QII", header, 72)
    partitions = []
    for i in range(num_entries):
        entry = _read_at(f, entries_lba * block_size + i * entry_size, entry_size)
        type_guid = entry[:16]
        if type_guid == b"\x00" * 16:
            continue  # unused entry slot
        first_lba, last_lba = struct.unpack_from("<QQ", entry, 32)
        start = first_lba * block_size
        size = (last_lba - first_lba + 1) * block_size
        partitions.append(_partition(start, size, i + 1))
    return partitions


def get_partitions(f):
    """Return partitions sorted by disk position (start offset), matching
    partitioninfo's index numbering and etcher-sdk's getDiskSizeAndPartitions."""
    mbr_entries = _mbr_entries(_read_at(f, 0, SECTOR_SIZE))
    if mbr_entries and mbr_entries[0]["type"] == GPT_PROTECTIVE_MBR_TYPE:
        # Block size may be 512/1024/2048/4096; the GPT header follows the
        # (protective) first block, so probe each candidate.
        for block_size in (512, 1024, 2048, 4096):
            partitions = _parse_gpt(f, block_size)
            if partitions is not None:
                return sorted(partitions, key=lambda p: p["start"])
        raise ValueError("Protective MBR present but no valid GPT header found")
    return sorted(_parse_mbr(f), key=lambda p: p["start"])


# --- functional core: part planning ----------------------------------------


def plan_parts(partitions, size):
    """Produce the ordered list of byte ranges to cache.

    Emits a gap part for space before each partition, a partition part for each
    partition (carrying its index), and a trailing gap part if the last
    partition ends before EOF. Mirrors cacheRawImageParts' loop.
    """
    parts = []
    last_end = -1
    for partition in partitions:
        if partition["start"] != last_end + 1:
            parts.append({"start": last_end + 1, "end": partition["start"] - 1})
        parts.append(
            {
                "start": partition["start"],
                "end": partition["end"],
                "partition_index": partition["index"],
            }
        )
        last_end = partition["end"]
    if last_end != size - 1:
        parts.append({"start": last_end + 1, "end": size - 1})
    return parts


# --- imperative shell: compression + output --------------------------------


def compress_range(f, start, end, out_path):
    """Compress the inclusive byte range [start, end] of ``f`` into a DEFLATE part.

    Streams the data through zlib so partitions never load fully into memory.
    Returns the part metadata: crc (of the uncompressed bytes), len (uncompressed
    byte count) and zLen (compressed byte count).
    """
    co = zlib.compressobj(zlib.Z_DEFAULT_COMPRESSION, zlib.DEFLATED, -zlib.MAX_WBITS)
    crc = 0
    uncompressed_len = 0
    compressed_len = 0
    remaining = end - start + 1
    f.seek(start)
    with open(out_path, "wb") as out:
        while remaining > 0:
            chunk = f.read(min(CHUNK_SIZE, remaining))
            if not chunk:
                raise ValueError(f"Unexpected EOF reading range [{start}, {end}]")
            remaining -= len(chunk)
            uncompressed_len += len(chunk)
            crc = zlib.crc32(chunk, crc)
            blob = co.compress(chunk)
            if blob:
                compressed_len += len(blob)
                out.write(blob)
        # Z_SYNC_FLUSH ends the stream on an empty, non-final block (00 00 ff ff)
        # so parts remain concatenatable; matches gzip-stream's stripped output.
        blob = co.flush(zlib.Z_SYNC_FLUSH)
        compressed_len += len(blob)
        out.write(blob)
    return {"crc": crc & 0xFFFFFFFF, "len": uncompressed_len, "zLen": compressed_len}


def prepare_raw_image(image_path, output_dir, suffix=""):
    """Compress ``image_path`` into compressed{suffix}/part-N.deflate parts and
    write the image{suffix}.json manifest under ``output_dir``."""
    size = os.path.getsize(image_path)
    with open(image_path, "rb") as f:
        partitions = get_partitions(f)
        parts = plan_parts(partitions, size)

        compressed_dir = os.path.join(output_dir, f"compressed{suffix}")
        os.makedirs(compressed_dir, exist_ok=True)

        metadata = []
        for i, part in enumerate(parts):
            filename = f"part-{i}.deflate"
            result = compress_range(
                f, part["start"], part["end"], os.path.join(compressed_dir, filename)
            )
            entry = {"filename": filename, **result}
            if "partition_index" in part:
                entry["partitionIndex"] = f"({part['partition_index']})"
            metadata.append(entry)

    manifest_path = os.path.join(output_dir, f"image{suffix}.json")
    with open(manifest_path, "w") as out:
        json.dump({"resin.img": {"parts": metadata}}, out, indent=4)
    return manifest_path


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compress a balenaOS raw disk image into DEFLATE parts + manifest."
    )
    parser.add_argument("image", help="Path to the raw .img file to compress")
    parser.add_argument(
        "-o",
        "--output-dir",
        help="Directory to write compressed{suffix}/ and image{suffix}.json "
        "(default: the image's directory)",
    )
    parser.add_argument(
        "--image-type",
        default="",
        help="Image type for output naming, e.g. 'flasher' -> compressed-flasher/ "
        "and image-flasher.json (default: none -> compressed/ and image.json)",
    )
    args = parser.parse_args(argv)
    suffix = f"-{args.image_type}" if args.image_type else ""

    # Match the original script: allow files/folders to be removed from outside
    # the build container by a non-root user.
    os.umask(0)

    if not os.path.isfile(args.image):
        parser.error(f"Image not found: {args.image}")
    output_dir = args.output_dir or os.path.dirname(os.path.abspath(args.image))

    manifest_path = prepare_raw_image(args.image, output_dir, suffix)
    print(f"Prepared compressed parts and {os.path.basename(manifest_path)}")


if __name__ == "__main__":
    sys.exit(main())
