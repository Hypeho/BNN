#!/usr/bin/env python3
"""Verify eBNN DMEM data and the separately stored Wide-BRAM weights."""

from __future__ import annotations

import argparse
import re
import struct
from pathlib import Path


DMEM_BASE = 0x20000000


def parse_array(text: str, c_type: str, name: str) -> list[str]:
    match = re.search(
        rf"{re.escape(c_type)}\s+{re.escape(name)}\s*\[[0-9]+\]\s*=\s*\{{(.*?)\}};",
        text,
        flags=re.S,
    )
    if not match:
        raise RuntimeError(f"source array not found: {name}")
    return re.findall(r"-?(?:0x[0-9a-fA-F]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)", match.group(1))


def array_bytes(text: str, c_type: str, name: str) -> bytes:
    values = parse_array(text, c_type, name)
    if c_type == "uint8_t":
        return bytes(int(value, 0) & 0xFF for value in values)
    if c_type == "float":
        return b"".join(struct.pack("<f", float(value)) for value in values)
    raise RuntimeError(f"unsupported C type: {c_type}")


def parse_symbols(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]+)\s+\S\s+(\S+)", line.strip())
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)
    return symbols


def parse_image(path: Path) -> dict[int, int]:
    words: dict[int, int] = {}
    address = 0
    for token in path.read_text(encoding="ascii").split():
        if token.startswith("@"):
            address = int(token[1:], 16)
        else:
            words[address] = int(token, 16)
            address += 1
    return words


def read_bytes(words: dict[int, int], absolute_address: int, size: int) -> bytes:
    offset = absolute_address - DMEM_BASE
    if offset < 0:
        raise RuntimeError(f"symbol is outside DMEM: 0x{absolute_address:08x}")
    output = bytearray()
    for byte_offset in range(size):
        current = offset + byte_offset
        word_index = current // 4
        lane = current & 3
        if word_index not in words:
            raise RuntimeError(f"DMEM word is missing: 0x{word_index:08x}")
        output.append((words[word_index] >> (lane * 8)) & 0xFF)
    return bytes(output)


def pack_lsb_words(data: bytes, bit_count: int, padded_words: int) -> list[int]:
    words = [0] * padded_words
    for bit in range(bit_count):
        source_bit = (data[bit // 8] >> (7 - (bit % 8))) & 1
        words[bit // 32] |= source_bit << (bit % 32)
    return words


def expected_weight_words(model_text: str) -> list[int]:
    conv = array_bytes(model_text, "uint8_t", "l_b_conv_pool_bn_bst0_bconv_W")
    fc = array_bytes(model_text, "uint8_t", "l_b_linear_bn_softmax1_bl_W")
    words: list[int] = []
    for output in range(10):
        words.extend(pack_lsb_words(conv[output * 2:(output + 1) * 2], 9, 4))
    for output in range(10):
        words.extend(pack_lsb_words(fc[output * 45:(output + 1) * 45], 360, 12))
    return words


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-header", type=Path, required=True)
    parser.add_argument("--model-header", type=Path, required=True)
    parser.add_argument("--nm", type=Path, required=True)
    parser.add_argument("--dmem", type=Path, required=True)
    parser.add_argument("--weight-image", type=Path, required=True)
    args = parser.parse_args()

    data_text = args.data_header.read_text(encoding="utf-8")
    model_text = args.model_header.read_text(encoding="utf-8")
    symbols = parse_symbols(args.nm)
    words = parse_image(args.dmem)
    arrays = [
        (data_text, "uint8_t", "train_data"),
        (data_text, "float", "train_labels"),
        (model_text, "float", "l_b_conv_pool_bn_bst0_bconv_b"),
        (model_text, "float", "l_b_conv_pool_bn_bst0_bn_beta"),
        (model_text, "float", "l_b_conv_pool_bn_bst0_bn_gamma"),
        (model_text, "float", "l_b_conv_pool_bn_bst0_bn_mean"),
        (model_text, "float", "l_b_conv_pool_bn_bst0_bn_std"),
        (model_text, "float", "l_b_linear_bn_softmax1_bl_b"),
        (model_text, "float", "l_b_linear_bn_softmax1_bn_beta"),
        (model_text, "float", "l_b_linear_bn_softmax1_bn_gamma"),
        (model_text, "float", "l_b_linear_bn_softmax1_bn_mean"),
        (model_text, "float", "l_b_linear_bn_softmax1_bn_std"),
    ]

    mismatch_count = 0
    total_bytes = 0
    for text, c_type, name in arrays:
        if name not in symbols:
            raise RuntimeError(f"ELF symbol not found: {name}")
        expected = array_bytes(text, c_type, name)
        actual = read_bytes(words, symbols[name], len(expected))
        total_bytes += len(expected)
        if actual == expected:
            print(
                f"DMEM_ARRAY_GATE name={name} address=0x{symbols[name]:08x} "
                f"bytes={len(expected)} result=PASS"
            )
            continue
        mismatch_count += 1
        first = next(index for index in range(len(expected)) if actual[index] != expected[index])
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

    expected_weights = expected_weight_words(model_text)
    actual_weights = parse_image(args.weight_image)
    weight_mismatches = [
        index for index, expected in enumerate(expected_weights)
        if actual_weights.get(index) != expected
    ]
    if weight_mismatches:
        index = weight_mismatches[0]
        actual = actual_weights.get(index)
        actual_text = "missing" if actual is None else f"0x{actual:08x}"
        print(
            f"WIDE_BRAM_WEIGHT_GATE words={len(expected_weights)} first_mismatch={index} "
            f"expected=0x{expected_weights[index]:08x} actual={actual_text} result=FAIL"
        )
        raise SystemExit(1)
    print(f"WIDE_BRAM_WEIGHT_GATE words={len(expected_weights)} result=PASS")


if __name__ == "__main__":
    main()
