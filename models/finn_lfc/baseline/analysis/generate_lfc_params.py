#!/usr/bin/env python3

"""Convert FINN LFC-W1A1 ONNX parameters into an RV32I packed-BNN image."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper


LAYER_SPECS = (
    ("33", "34", "features.3", 784, 1024),
    ("41", "42", "features.7", 1024, 1024),
    ("49", "50", "features.11", 1024, 1024),
)
FINAL_SPEC = ("57", "58", 1024, 10)


def pack_pm1(values: np.ndarray) -> np.ndarray:
    flat = np.asarray(values).reshape(-1)
    words = np.zeros((flat.size + 31) // 32, dtype=np.uint32)
    for index, value in enumerate(flat):
        if value > 0:
            words[index // 32] |= np.uint32(1 << (index % 32))
    return words


def parse_ebnn_first_sample(path: Path) -> np.ndarray:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"train_data\[\d+\]\s*=\s*\{([^}]*)\}", text, re.S)
    if not match:
        raise RuntimeError(f"train_data array not found in {path}")
    packed = [int(x) for x in re.findall(r"\d+", match.group(1))[:98]]
    bits = []
    for byte in packed:
        bits.extend(1.0 if byte & (1 << (7 - bit)) else 0.0 for bit in range(8))
    return np.asarray(bits[:784], dtype=np.float32).reshape(1, 1, 28, 28)


def bn_epsilon(node: onnx.NodeProto) -> float:
    for attr in node.attribute:
        if attr.name == "epsilon":
            return float(attr.f)
    return 1e-5


def emit_u32(name: str, values: np.ndarray, output: list[str]) -> None:
    flat = np.asarray(values, dtype=np.uint32).reshape(-1)
    output.append(f"static const uint32_t {name}[{flat.size}] __attribute__((aligned(4))) = {{")
    for start in range(0, flat.size, 8):
        chunk = ", ".join(f"0x{int(x):08x}u" for x in flat[start : start + 8])
        output.append(f"  {chunk},")
    output.append("};")


def emit_u16(name: str, values: np.ndarray, output: list[str]) -> None:
    flat = np.asarray(values, dtype=np.uint16).reshape(-1)
    output.append(f"static const uint16_t {name}[{flat.size}] __attribute__((aligned(4))) = {{")
    for start in range(0, flat.size, 16):
        chunk = ", ".join(str(int(x)) for x in flat[start : start + 16])
        output.append(f"  {chunk},")
    output.append("};")


def threshold_from_affine(
    input_size: int,
    scale: np.ndarray,
    gamma: np.ndarray,
    beta: np.ndarray,
    mean: np.ndarray,
    variance: np.ndarray,
    epsilon: float,
) -> tuple[np.ndarray, np.ndarray]:
    inv_std = 1.0 / np.sqrt(variance.astype(np.float64) + epsilon)
    alpha = gamma.astype(np.float64) * scale.astype(np.float64) * inv_std
    offset = beta.astype(np.float64) - gamma.astype(np.float64) * mean.astype(np.float64) * inv_std
    thresholds = np.empty(alpha.size, dtype=np.uint16)
    polarity = np.empty(alpha.size, dtype=np.bool_)
    matches = np.arange(input_size + 1, dtype=np.float64)
    dots = 2.0 * matches - input_size
    for index, (a, b) in enumerate(zip(alpha, offset)):
        positive = a * dots + b > 0.0
        if a >= 0.0:
            polarity[index] = True
            positions = np.flatnonzero(positive)
            thresholds[index] = int(positions[0]) if positions.size else input_size + 1
        else:
            polarity[index] = False
            positions = np.flatnonzero(~positive)
            thresholds[index] = int(positions[0]) if positions.size else input_size + 1
    return thresholds, pack_pm1(np.where(polarity, 1, -1))


def xnor_matches(a: np.ndarray, b: np.ndarray, valid_bits: int) -> int:
    xor = np.bitwise_xor(a, b)
    matches = sum(int((~int(x) & 0xFFFFFFFF).bit_count()) for x in xor)
    invalid = len(a) * 32 - valid_bits
    if invalid:
        mask = (1 << (32 - invalid)) - 1
        tail = (~int(xor[-1])) & 0xFFFFFFFF
        matches -= tail.bit_count() - (tail & mask).bit_count()
    return matches


def packed_inference(
    input_words: np.ndarray,
    packed_weights: list[np.ndarray],
    thresholds: list[np.ndarray],
    polarities: list[np.ndarray],
) -> tuple[int, list[int]]:
    activation = input_words
    input_sizes = [784, 1024, 1024]
    for layer, input_size in enumerate(input_sizes):
        output_bits = np.zeros(32, dtype=np.uint32)
        words_per_neuron = (input_size + 31) // 32
        for neuron in range(1024):
            weight = packed_weights[layer][neuron * words_per_neuron : (neuron + 1) * words_per_neuron]
            matches = xnor_matches(activation, weight, input_size)
            ge = matches >= int(thresholds[layer][neuron])
            polarity = bool((int(polarities[layer][neuron // 32]) >> (neuron % 32)) & 1)
            if ge == polarity:
                output_bits[neuron // 32] |= np.uint32(1 << (neuron % 32))
        activation = output_bits
    final_weights = packed_weights[3]
    scores = []
    for neuron in range(10):
        weight = final_weights[neuron * 32 : (neuron + 1) * 32]
        scores.append(2 * xnor_matches(activation, weight, 1024) - 1024)
    return int(np.argmax(scores)), scores


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", type=Path, required=True)
    parser.add_argument("--ebnn-data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    model = onnx.load(args.onnx)
    initializers = {x.name: numpy_helper.to_array(x) for x in model.graph.initializer}
    bn_nodes = {node.input[1].rsplit(".weight", 1)[0]: node for node in model.graph.node if node.op_type == "BatchNormalization"}
    sample = parse_ebnn_first_sample(args.ebnn_data)
    session = ort.InferenceSession(str(args.onnx), providers=["CPUExecutionProvider"])
    logits = session.run(None, {session.get_inputs()[0].name: sample})[0].reshape(-1)
    expected = int(np.argmax(logits))

    weights: list[np.ndarray] = []
    layer_thresholds: list[np.ndarray] = []
    layer_polarities: list[np.ndarray] = []
    for weight_name, scale_name, bn_prefix, input_size, output_size in LAYER_SPECS:
        matrix = initializers[weight_name]
        packed = np.concatenate([pack_pm1(matrix[:, neuron]) for neuron in range(output_size)])
        weights.append(packed)
        node = bn_nodes[bn_prefix]
        threshold, polarity = threshold_from_affine(
            input_size,
            initializers[scale_name].reshape(-1),
            initializers[f"{bn_prefix}.weight"],
            initializers[f"{bn_prefix}.bias"],
            initializers[f"{bn_prefix}.running_mean"],
            initializers[f"{bn_prefix}.running_var"],
            bn_epsilon(node),
        )
        layer_thresholds.append(threshold)
        layer_polarities.append(polarity)

    final_weight_name, _, final_input, final_output = FINAL_SPEC
    final_matrix = initializers[final_weight_name]
    weights.append(np.concatenate([pack_pm1(final_matrix[:, neuron]) for neuron in range(final_output)]))
    input_pm1 = np.where(sample.reshape(-1) > 0.5, 1, -1)
    input_words = pack_pm1(input_pm1)
    packed_prediction, scores = packed_inference(
        input_words, weights, layer_thresholds, layer_polarities
    )
    if packed_prediction != expected:
        raise RuntimeError(f"packed inference {packed_prediction} != ONNX {expected}")

    rng = np.random.default_rng(260719)
    random_verified = 0
    for _ in range(8):
        random_sample = rng.integers(0, 2, size=(1, 1, 28, 28)).astype(np.float32)
        random_logits = session.run(None, {session.get_inputs()[0].name: random_sample})[0]
        random_expected = int(np.argmax(random_logits))
        random_words = pack_pm1(np.where(random_sample.reshape(-1) > 0.5, 1, -1))
        random_prediction, _ = packed_inference(
            random_words, weights, layer_thresholds, layer_polarities
        )
        if random_prediction != random_expected:
            raise RuntimeError(
                f"random packed inference {random_prediction} != ONNX {random_expected}"
            )
        random_verified += 1

    output = [
        "#ifndef FINN_LFC_PARAMS_H",
        "#define FINN_LFC_PARAMS_H",
        "#include <stdint.h>",
        f"#define LFC_EXPECTED_CLASS {expected}",
    ]
    emit_u32("lfc_input", input_words, output)
    for layer in range(4):
        emit_u32(f"lfc_w{layer}", weights[layer], output)
    for layer in range(3):
        emit_u16(f"lfc_threshold{layer}", layer_thresholds[layer], output)
        emit_u32(f"lfc_polarity{layer}", layer_polarities[layer], output)
    output.extend(["#endif", ""])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(output), encoding="utf-8")
    print(f"ONNX prediction={expected} logits={logits.tolist()}")
    print(f"packed prediction={packed_prediction} integer_scores={scores}")
    print(f"random_binary_inputs_verified={random_verified}")
    print(f"generated={args.output} bytes={args.output.stat().st_size}")


if __name__ == "__main__":
    main()
