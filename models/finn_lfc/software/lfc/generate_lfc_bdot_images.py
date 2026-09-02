#!/usr/bin/env python3
"""Generate aligned FINN LFC images and self-check their golden inference."""

import hashlib
import json
import re
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[2]
SOURCE_HEADER = PROJECT_DIR.parent / "260719_FINN_LFC_RV32I/generated/lfc_params.h"
OUTPUT_DIR = Path(__file__).resolve().parent / "generated"

ACT0_BASE = 0x30000000
ACT1_BASE = 0x30010000
WEIGHT_BASE = 0x40000000
ACT_WORDS = 32 * 1024 // 4
WEIGHT_WORDS = 400 * 1024 // 4


def parse_array(text, ctype, name):
    pattern = (
        rf"static\s+const\s+{re.escape(ctype)}\s+{re.escape(name)}"
        rf"\s*\[[0-9]+\].*?=\s*\{{(.*?)\}};"
    )
    match = re.search(pattern, text, flags=re.S)
    if not match:
        raise RuntimeError(f"array {name} was not found")
    tokens = re.findall(r"0x[0-9a-fA-F]+|[0-9]+", match.group(1))
    return [int(token, 0) for token in tokens]


def pack_layer(inputs, weights, weight_offset, stride_words, thresholds, polarities, input_bits, outputs):
    output_words = [0] * ((outputs + 31) // 32)
    for neuron in range(outputs):
        matches = 0
        base = weight_offset + neuron * stride_words
        for bit in range(input_bits):
            input_bit = (inputs[bit // 32] >> (bit % 32)) & 1
            weight_bit = (weights[base + bit // 32] >> (bit % 32)) & 1
            matches += input_bit == weight_bit
        ge = matches >= thresholds[neuron]
        polarity = (polarities[neuron // 32] >> (neuron % 32)) & 1
        if ge == bool(polarity):
            output_words[neuron // 32] |= 1 << (neuron % 32)
    return output_words


def run_aligned_inference(input_words, weights, offsets, strides, thresholds, polarities):
    layer0 = pack_layer(input_words, weights, offsets[0], strides[0], thresholds[0], polarities[0], 784, 1024)
    layer1 = pack_layer(layer0, weights, offsets[1], strides[1], thresholds[1], polarities[1], 1024, 1024)
    layer2 = pack_layer(layer1, weights, offsets[2], strides[2], thresholds[2], polarities[2], 1024, 1024)

    scores = []
    for neuron in range(10):
        matches = 0
        base = offsets[3] + neuron * strides[3]
        for bit in range(1024):
            lhs = (layer2[bit // 32] >> (bit % 32)) & 1
            rhs = (weights[base + bit // 32] >> (bit % 32)) & 1
            matches += lhs == rhs
        scores.append(2 * matches - 1024)
    prediction = max(range(10), key=lambda index: scores[index])
    return prediction, scores, [layer0, layer1, layer2]


def write_hex(path, words):
    path.write_text("".join(f"{word & 0xffffffff:08x}\n" for word in words))


def write_c_array(handle, ctype, name, values, per_line):
    handle.write(f"static const {ctype} {name}[{len(values)}] __attribute__((aligned(4))) = {{\n")
    for index in range(0, len(values), per_line):
        chunk = values[index:index + per_line]
        if ctype == "uint32_t":
            rendered = ", ".join(f"0x{value:08x}u" for value in chunk)
        else:
            rendered = ", ".join(str(value) for value in chunk)
        handle.write(f"    {rendered},\n")
    handle.write("};\n\n")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    text = SOURCE_HEADER.read_text()
    input_words = parse_array(text, "uint32_t", "lfc_input")
    original_weights = [parse_array(text, "uint32_t", f"lfc_w{layer}") for layer in range(4)]
    thresholds = [parse_array(text, "uint16_t", f"lfc_threshold{layer}") for layer in range(3)]
    polarities = [parse_array(text, "uint32_t", f"lfc_polarity{layer}") for layer in range(3)]

    expected_lengths = [25600, 32768, 32768, 320]
    if [len(values) for values in original_weights] != expected_lengths:
        raise RuntimeError("unexpected weight array length")
    if len(input_words) != 25:
        raise RuntimeError("unexpected LFC input length")

    aligned_weights = []
    offsets = []
    strides = [28, 32, 32, 32]
    neuron_counts = [1024, 1024, 1024, 10]
    source_strides = [25, 32, 32, 32]
    for layer in range(4):
        while len(aligned_weights) % 4:
            aligned_weights.append(0)
        offsets.append(len(aligned_weights))
        source = original_weights[layer]
        for neuron in range(neuron_counts[layer]):
            begin = neuron * source_strides[layer]
            aligned_weights.extend(source[begin:begin + source_strides[layer]])
            aligned_weights.extend([0] * (strides[layer] - source_strides[layer]))

    if offsets != [0x00000 // 4, 0x1C000 // 4, 0x3C000 // 4, 0x5C000 // 4]:
        raise RuntimeError(f"unexpected layer offsets: {offsets}")
    if len(aligned_weights) != 378112 // 4:
        raise RuntimeError("unexpected aligned weight size")
    if len(aligned_weights) > WEIGHT_WORDS:
        raise RuntimeError("aligned weight image exceeds the 400 KiB physical BRAM")

    prediction, scores, activations = run_aligned_inference(
        input_words, aligned_weights, offsets, strides, thresholds, polarities
    )
    expected_scores = [-182, -94, -34, 326, -162, 556, 54, 6, 216, -96]
    if prediction != 5 or scores != expected_scores:
        raise RuntimeError(f"aligned image golden mismatch: prediction={prediction}, scores={scores}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    weight_image = aligned_weights + [0] * (WEIGHT_WORDS - len(aligned_weights))
    activation0 = input_words + [0] * (ACT_WORDS - len(input_words))
    activation1 = [0] * ACT_WORDS

    weight_path = OUTPUT_DIR / "weight_128.hex"
    act0_path = OUTPUT_DIR / "activation0.hex"
    act1_path = OUTPUT_DIR / "activation1.hex"
    write_hex(weight_path, weight_image)
    write_hex(act0_path, activation0)
    write_hex(act1_path, activation1)
    for layer, words in enumerate(activations):
        write_hex(OUTPUT_DIR / f"golden_activation{layer}.hex", words)

    header_path = OUTPUT_DIR / "lfc_bdot_params.h"
    with header_path.open("w") as handle:
        handle.write("#ifndef LFC_BDOT_PARAMS_H\n#define LFC_BDOT_PARAMS_H\n#include <stdint.h>\n\n")
        handle.write("#define LFC_EXPECTED_CLASS 5\n")
        handle.write(f"#define LFC_ACT0_BASE 0x{ACT0_BASE:08x}u\n")
        handle.write(f"#define LFC_ACT1_BASE 0x{ACT1_BASE:08x}u\n")
        handle.write(f"#define LFC_WEIGHT_BASE 0x{WEIGHT_BASE:08x}u\n")
        for layer in range(4):
            handle.write(f"#define LFC_W{layer}_BASE (LFC_WEIGHT_BASE + 0x{offsets[layer] * 4:05x}u)\n")
            handle.write(f"#define LFC_W{layer}_STRIDE {strides[layer] * 4}u\n")
        handle.write("\n")
        for layer in range(3):
            write_c_array(handle, "uint16_t", f"lfc_threshold{layer}", thresholds[layer], 16)
            write_c_array(handle, "uint32_t", f"lfc_polarity{layer}", polarities[layer], 8)
        handle.write("#endif\n")

    metadata = {
        "source": str(SOURCE_HEADER),
        "prediction": prediction,
        "scores": scores,
        "weight_words_used": len(aligned_weights),
        "weight_bytes_used": len(aligned_weights) * 4,
        "weight_words_allocated": WEIGHT_WORDS,
        "activation_words_allocated": ACT_WORDS,
        "layers": [
            {
                "name": f"W{layer}",
                "offset_bytes": offsets[layer] * 4,
                "stride_bytes": strides[layer] * 4,
                "neurons": neuron_counts[layer],
            }
            for layer in range(4)
        ],
        "sha256": {
            "weight_128.hex": sha256(weight_path),
            "activation0.hex": sha256(act0_path),
            "activation1.hex": sha256(act1_path),
            "lfc_bdot_params.h": sha256(header_path),
        },
    }
    (OUTPUT_DIR / "lfc_bdot_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"PASS prediction={prediction} scores={scores}")
    print(f"weight_bytes_used={len(aligned_weights) * 4} weight_words={len(aligned_weights)}")
    print(f"offsets_bytes={[offset * 4 for offset in offsets]}")


if __name__ == "__main__":
    main()
