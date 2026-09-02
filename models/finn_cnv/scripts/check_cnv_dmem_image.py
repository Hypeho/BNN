#!/usr/bin/env python3
"""Compare every CPU-side FINN CNV parameter byte against a DMEM image."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np


DMEM_BASE = 0x20000000


def parse_array(text: str, name: str, dtype: np.dtype) -> np.ndarray:
    match = re.search(
        rf"static\s+const\s+\w+_t\s+{re.escape(name)}\s*"
        rf"\[[0-9]+\].*?=\s*\{{(.*?)\}};",
        text,
        flags=re.S,
    )
    if not match:
        raise RuntimeError(f"header array not found: {name}")
    values = re.findall(r"-?0x[0-9a-fA-F]+|-?[0-9]+", match.group(1))
    return np.asarray([int(value, 0) for value in values], dtype=dtype)


def parse_symbols(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]+)\s+\S\s+(\S+)", line.strip())
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)
    return symbols


def parse_dmem(path: Path) -> dict[int, int]:
    words: dict[int, int] = {}
    address = 0
    for token in path.read_text(encoding="ascii").split():
        if token.startswith("@"):
            address = int(token[1:], 16)
        else:
            words[address] = int(token, 16)
            address += 1
    return words


def image_bytes(words: dict[int, int], address: int, size: int) -> bytes:
    result = bytearray()
    offset = address - DMEM_BASE
    if offset < 0:
        raise RuntimeError(f"address below DMEM: 0x{address:08x}")
    for byte_offset in range(size):
        absolute_offset = offset + byte_offset
        word_index = absolute_offset // 4
        lane = absolute_offset % 4
        if word_index not in words:
            raise RuntimeError(f"missing DMEM word 0x{word_index:08x}")
        result.append((words[word_index] >> (8 * lane)) & 0xFF)
    return bytes(result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--header", type=Path, required=True)
    parser.add_argument("--nm", type=Path, required=True)
    parser.add_argument("--dmem", type=Path, required=True)
    args = parser.parse_args()

    header = args.header.read_text(encoding="utf-8")
    symbols = parse_symbols(args.nm)
    words = parse_dmem(args.dmem)

    arrays: list[tuple[str, np.dtype]] = [
        ("cnv_expected_layer_checksums", np.dtype("<u4")),
        ("cnv_fc_polarity0", np.dtype("<u4")),
        ("cnv_fc_polarity1", np.dtype("<u4")),
        ("cnv_fc_threshold0", np.dtype("<u2")),
        ("cnv_fc_threshold1", np.dtype("<u2")),
        ("cnv_input_q7_hwc", np.dtype("i1")),
        ("cnv_polarity2", np.dtype("<u4")),
        ("cnv_polarity3", np.dtype("<u4")),
        ("cnv_polarity4", np.dtype("<u4")),
        ("cnv_polarity5", np.dtype("<u4")),
        ("cnv_threshold0", np.dtype("<i2")),
        ("cnv_threshold1", np.dtype("<u2")),
        ("cnv_threshold2", np.dtype("<u2")),
        ("cnv_threshold3", np.dtype("<u2")),
        ("cnv_threshold4", np.dtype("<u2")),
        ("cnv_threshold5", np.dtype("<u2")),
        ("cnv_w0_i8", np.dtype("i1")),
        ("cnv_polarity0", np.dtype("<u4")),
        ("cnv_polarity1", np.dtype("<u4")),
    ]

    mismatch_count = 0
    total_bytes = 0
    for name, dtype in arrays:
        if name not in symbols:
            raise RuntimeError(f"symbol not found: {name}")
        expected = parse_array(header, name, dtype).tobytes()
        actual = image_bytes(words, symbols[name], len(expected))
        total_bytes += len(expected)
        if actual == expected:
            print(
                f"DMEM_ARRAY_GATE name={name} address=0x{symbols[name]:08x} "
                f"bytes={len(expected)} result=PASS"
            )
            continue
        mismatch_count += 1
        first = next(index for index, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1])
        print(
            f"DMEM_ARRAY_GATE name={name} address=0x{symbols[name]:08x} "
            f"bytes={len(expected)} first_mismatch={first} "
            f"expected=0x{expected[first]:02x} actual=0x{actual[first]:02x} result=FAIL"
        )

    result = "PASS" if mismatch_count == 0 else "FAIL"
    print(
        f"DMEM_FULL_GATE arrays={len(arrays)} bytes={total_bytes} "
        f"mismatches={mismatch_count} result={result}"
    )
    if mismatch_count:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
