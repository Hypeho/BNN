#!/usr/bin/env python3
"""Generate dependency-free FINN LFC golden vectors for Binary-MNIST cases.

The input bytes come from the eBNN project, but every expected activation,
score, and prediction is recomputed with the FINN LFC parameters.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
MODEL_DIR = SCRIPT_DIR.parents[1]
MODELS_DIR = MODEL_DIR.parent
LFC_HEADER = MODEL_DIR / "baseline" / "generated" / "lfc_params.h"
EBNN_HEADER = MODELS_DIR / "ebnn" / "baseline" / "common" / "binary_mnist_data.h"
DEFAULT_OUTPUT = MODEL_DIR / "vectors" / "generated" / "multiinput"
EXISTING_WEIGHT_IMAGE = SCRIPT_DIR / "generated" / "weight_128.hex"
EXISTING_INPUT_IMAGE = SCRIPT_DIR / "generated" / "activation0.hex"
EXISTING_GOLDEN_ACTIVATIONS = [
    SCRIPT_DIR / "generated" / f"golden_activation{layer}.hex" for layer in range(3)
]

ACT_WORDS = 8192
WEIGHT_WORDS = 102400
INPUT_BITS = 784
INPUT_BYTES = 98
EXPECTED_SAMPLE0_SCORES = [-182, -94, -34, 326, -162, 556, 54, 6, 216, -96]


def parse_initializer(text: str, name: str) -> list[int]:
    match = re.search(
        rf"\b{re.escape(name)}\s*\[[^\]]*\][^=;]*=\s*\{{(.*?)\}}\s*;",
        text,
        re.S,
    )
    if not match:
        raise RuntimeError(f"array {name!r} was not found")
    return [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|\d+", match.group(1))]


def pack_binary_mnist(sample_bytes: list[int]) -> list[int]:
    """Map byte MSB-first pixels to consecutive uint32 LSB-first bit indices."""
    if len(sample_bytes) != INPUT_BYTES:
        raise RuntimeError(f"expected {INPUT_BYTES} input bytes, got {len(sample_bytes)}")
    words = [0] * 25
    for bit_index in range(INPUT_BITS):
        value = (sample_bytes[bit_index // 8] >> (7 - (bit_index % 8))) & 1
        words[bit_index // 32] |= value << (bit_index % 32)
    return words


def aligned_weight_image(header_text: str):
    source_weights = [parse_initializer(header_text, f"lfc_w{layer}") for layer in range(4)]
    thresholds = [parse_initializer(header_text, f"lfc_threshold{layer}") for layer in range(3)]
    polarities = [parse_initializer(header_text, f"lfc_polarity{layer}") for layer in range(3)]
    expected_lengths = [25600, 32768, 32768, 320]
    if [len(values) for values in source_weights] != expected_lengths:
        raise RuntimeError("unexpected FINN LFC weight dimensions")

    source_strides = [25, 32, 32, 32]
    aligned_strides = [28, 32, 32, 32]
    neurons = [1024, 1024, 1024, 10]
    weights: list[int] = []
    offsets: list[int] = []
    for layer in range(4):
        while len(weights) % 4:
            weights.append(0)
        offsets.append(len(weights))
        source = source_weights[layer]
        for neuron in range(neurons[layer]):
            begin = neuron * source_strides[layer]
            weights.extend(source[begin : begin + source_strides[layer]])
            weights.extend([0] * (aligned_strides[layer] - source_strides[layer]))

    expected_offsets = [0x00000 // 4, 0x1C000 // 4, 0x3C000 // 4, 0x5C000 // 4]
    if offsets != expected_offsets or len(weights) != 378112 // 4:
        raise RuntimeError(f"unexpected aligned weight layout: offsets={offsets}, words={len(weights)}")
    return weights, offsets, aligned_strides, thresholds, polarities


def binary_layer(inputs, weights, offset, stride, thresholds, polarities, input_bits, outputs):
    output_words = [0] * ((outputs + 31) // 32)
    input_word_count = (input_bits + 31) // 32
    for neuron in range(outputs):
        base = offset + neuron * stride
        matches = 0
        for word_index in range(input_word_count):
            valid_bits = min(32, input_bits - word_index * 32)
            mask = (1 << valid_bits) - 1
            mismatches = ((inputs[word_index] ^ weights[base + word_index]) & mask).bit_count()
            matches += valid_bits - mismatches
        ge_threshold = matches >= thresholds[neuron]
        polarity = bool((polarities[neuron // 32] >> (neuron % 32)) & 1)
        if ge_threshold == polarity:
            output_words[neuron // 32] |= 1 << (neuron % 32)
    return output_words


def infer(input_words, weights, offsets, strides, thresholds, polarities):
    layer0 = binary_layer(input_words, weights, offsets[0], strides[0], thresholds[0], polarities[0], 784, 1024)
    layer1 = binary_layer(layer0, weights, offsets[1], strides[1], thresholds[1], polarities[1], 1024, 1024)
    layer2 = binary_layer(layer1, weights, offsets[2], strides[2], thresholds[2], polarities[2], 1024, 1024)
    scores = []
    for neuron in range(10):
        base = offsets[3] + neuron * strides[3]
        matches = sum(32 - (layer2[word] ^ weights[base + word]).bit_count() for word in range(32))
        scores.append(2 * matches - 1024)
    prediction = max(range(10), key=scores.__getitem__)
    return prediction, scores, [layer0, layer1, layer2]


def write_hex(path: Path, words):
    path.write_text("".join(f"{word & 0xffffffff:08x}\n" for word in words), encoding="ascii")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_existing_weight_image(weights):
    if not EXISTING_WEIGHT_IMAGE.is_file():
        raise RuntimeError(f"existing Wide-BDOT128 weight image is missing: {EXISTING_WEIGHT_IMAGE}")
    existing_words = [int(line, 16) for line in EXISTING_WEIGHT_IMAGE.read_text().splitlines() if line.strip()]
    if len(existing_words) != WEIGHT_WORDS:
        raise RuntimeError(f"existing weight image has {len(existing_words)} words, expected {WEIGHT_WORDS}")
    if existing_words[: len(weights)] != weights or any(existing_words[len(weights) :]):
        raise RuntimeError("existing weight_128.hex does not match the FINN parameter-derived aligned image")


def read_hex_words(path: Path) -> list[int]:
    if not path.is_file():
        raise RuntimeError(f"required reference image is missing: {path}")
    return [int(line, 16) for line in path.read_text().splitlines() if line.strip()]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample-ids", nargs="*", type=int, default=None)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    lfc_text = LFC_HEADER.read_text(encoding="utf-8")
    ebnn_text = EBNN_HEADER.read_text(encoding="utf-8")
    reference_input = parse_initializer(lfc_text, "lfc_input")
    raw_inputs = parse_initializer(ebnn_text, "train_data")
    labels = parse_initializer(ebnn_text, "train_labels")
    if len(reference_input) != 25 or len(raw_inputs) % INPUT_BYTES:
        raise RuntimeError("unexpected input dimensions")
    sample_count = len(raw_inputs) // INPUT_BYTES
    if len(labels) != sample_count:
        raise RuntimeError("Binary-MNIST label count does not match input count")

    packed_inputs = [pack_binary_mnist(raw_inputs[index * INPUT_BYTES : (index + 1) * INPUT_BYTES]) for index in range(sample_count)]
    if packed_inputs[0] != reference_input:
        mismatches = [index for index, pair in enumerate(zip(packed_inputs[0], reference_input)) if pair[0] != pair[1]]
        raise RuntimeError(f"sample 0 representation does not match lfc_input; word mismatches={mismatches}")
    reference_input_image = read_hex_words(EXISTING_INPUT_IMAGE)
    expected_input_image = reference_input + [0] * (ACT_WORDS - len(reference_input))
    if reference_input_image != expected_input_image:
        raise RuntimeError("sample 0 packed input does not match the existing activation0.hex image")
    print("INPUT_REPRESENTATION_GATE PASS sample_id=0 bytes=98 bits=784 words=25 valid_bits_last_word=16")

    weights, offsets, strides, thresholds, polarities = aligned_weight_image(lfc_text)
    verify_existing_weight_image(weights)
    gate_prediction, gate_scores, gate_activations = infer(reference_input, weights, offsets, strides, thresholds, polarities)
    if gate_prediction != 5 or gate_scores != EXPECTED_SAMPLE0_SCORES:
        raise RuntimeError(f"sample 0 golden gate failed: prediction={gate_prediction}, scores={gate_scores}")
    for layer, (generated, path) in enumerate(zip(gate_activations, EXISTING_GOLDEN_ACTIVATIONS)):
        existing = read_hex_words(path)
        if generated != existing:
            mismatches = [index for index, pair in enumerate(zip(generated, existing)) if pair[0] != pair[1]]
            raise RuntimeError(f"sample 0 layer {layer} activation gate failed; word mismatches={mismatches}")
    print(
        f"GOLDEN_GATE PASS packed_input=PASS prediction={gate_prediction} "
        f"scores={gate_scores} layer0=PASS layer1=PASS layer2=PASS"
    )

    sample_ids = list(range(sample_count)) if args.sample_ids is None else args.sample_ids
    if not sample_ids:
        raise RuntimeError("no samples selected")
    if len(set(sample_ids)) != len(sample_ids) or any(index < 0 or index >= sample_count for index in sample_ids):
        raise RuntimeError(f"sample IDs must be unique values in 0..{sample_count - 1}")

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_cases = []
    for sample_id in sample_ids:
        prediction, scores, activations = infer(packed_inputs[sample_id], weights, offsets, strides, thresholds, polarities)
        case_dir = output_dir / f"case_{sample_id:02d}"
        case_dir.mkdir(parents=True, exist_ok=True)
        write_hex(case_dir / "activation0.hex", packed_inputs[sample_id] + [0] * (ACT_WORDS - 25))
        write_hex(case_dir / "activation1.hex", [0] * ACT_WORDS)
        for layer, words in enumerate(activations):
            write_hex(case_dir / f"golden_activation{layer}.hex", words)
        write_hex(case_dir / "expected_scores.hex", scores)
        metadata = {
            "model": "FINN_LFC",
            "sample_id": sample_id,
            "source": "260624_eBNN_Binary_MNIST/common/binary_mnist_data.h input only",
            "source_label": labels[sample_id],
            "expected_prediction": prediction,
            "expected_scores": scores,
            "input_representation": "784 pixels; source byte MSB-first; packed uint32 word/bit LSB-first",
            "sha256": {path.name: sha256(path) for path in sorted(case_dir.glob("*.hex"))},
        }
        (case_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        manifest_cases.append(metadata)
        print(f"CASE sample_id={sample_id} source_label={labels[sample_id]} prediction={prediction} scores={scores}")

    manifest = {
        "model": "FINN_LFC",
        "golden_gate": {
            "sample_id": 0,
            "packed_input_match": True,
            "prediction": gate_prediction,
            "scores": gate_scores,
            "layer0_match": True,
            "layer1_match": True,
            "layer2_match": True,
            "result": "PASS",
        },
        "input_count_available": sample_count,
        "generated_sample_ids": sample_ids,
        "parameter_source": str(LFC_HEADER),
        "input_source": str(EBNN_HEADER),
        "cases": manifest_cases,
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"GENERATED PASS cases={len(sample_ids)} output={output_dir}")


if __name__ == "__main__":
    main()
