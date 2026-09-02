#!/usr/bin/env python3
"""Generate padded Wide-BDOT128 images for the eBNN Binary-MNIST model."""

import json
import re
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parents[1]
SOURCE_DIR = PROJECT_DIR.parent / "260624_eBNN_Binary_MNIST"
MODEL_HEADER = SOURCE_DIR / "common" / "binary_mnist.h"
OUTPUT_DIR = SCRIPT_DIR / "generated"

ACT_WORDS = 32 * 1024 // 4
WEIGHT_WORDS = 400 * 1024 // 4
WEIGHT_BASE = 0x40000000


def parse_u8_array(text: str, name: str) -> list[int]:
    match = re.search(
        rf"uint8_t\s+{re.escape(name)}\s*\[[0-9]+\]\s*=\s*\{{(.*?)\}};",
        text,
        flags=re.S,
    )
    if not match:
        raise RuntimeError(f"array {name} was not found in {MODEL_HEADER}")
    return [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|[0-9]+", match.group(1))]


def source_bit(data: list[int], index: int) -> int:
    return (data[index // 8] >> (7 - index % 8)) & 1


def pack_lsb_words(data: list[int], bit_count: int, padded_words: int) -> list[int]:
    words = [0] * padded_words
    for bit in range(bit_count):
        words[bit // 32] |= source_bit(data, bit) << (bit % 32)
    return words


def write_hex(path: Path, words: list[int]) -> None:
    path.write_text("".join(f"{word & 0xffffffff:08x}\n" for word in words), encoding="ascii")


def main() -> None:
    text = MODEL_HEADER.read_text(encoding="utf-8")
    conv = parse_u8_array(text, "l_b_conv_pool_bn_bst0_bconv_W")
    fc = parse_u8_array(text, "l_b_linear_bn_softmax1_bl_W")

    image: list[int] = []
    conv_stride_words = 4
    for output in range(10):
        source = conv[output * 2:(output + 1) * 2]
        image.extend(pack_lsb_words(source, 9, conv_stride_words))

    fc_offset_words = len(image)
    fc_stride_words = 12
    for output in range(10):
        source = fc[output * 45:(output + 1) * 45]
        image.extend(pack_lsb_words(source, 360, fc_stride_words))

    used_words = len(image)
    if used_words > WEIGHT_WORDS:
        raise RuntimeError("eBNN weight image exceeds the 400 KiB Weight BRAM")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_hex(OUTPUT_DIR / "weight_128.hex", image + [0] * (WEIGHT_WORDS - used_words))
    write_hex(OUTPUT_DIR / "activation0.hex", [0] * ACT_WORDS)
    write_hex(OUTPUT_DIR / "activation1.hex", [0] * ACT_WORDS)

    params = OUTPUT_DIR / "ebnn_bdot_params.h"
    params.write_text(
        "\n".join([
            "#ifndef EBNN_BDOT_PARAMS_H",
            "#define EBNN_BDOT_PARAMS_H",
            "",
            f"#define EBNN_CONV_WEIGHT_BASE 0x{WEIGHT_BASE:08x}u",
            f"#define EBNN_CONV_WEIGHT_STRIDE {conv_stride_words * 4}u",
            f"#define EBNN_FC_WEIGHT_BASE 0x{WEIGHT_BASE + fc_offset_words * 4:08x}u",
            f"#define EBNN_FC_WEIGHT_STRIDE {fc_stride_words * 4}u",
            f"#define EBNN_WEIGHT_USED_WORDS {used_words}u",
            "",
            "#endif",
            "",
        ]),
        encoding="ascii",
    )

    metadata = {
        "model": "eBNN Binary-MNIST",
        "conv": {"input_bits": 9, "outputs": 10, "stride_bytes": 16},
        "fc": {"input_bits": 360, "outputs": 10, "stride_bytes": 48},
        "weight_bytes_used": used_words * 4,
        "weight_bytes_allocated": WEIGHT_WORDS * 4,
    }
    (OUTPUT_DIR / "ebnn_bdot_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    print(f"eBNN BDOT image PASS weight_bytes_used={used_words * 4}")


if __name__ == "__main__":
    main()
