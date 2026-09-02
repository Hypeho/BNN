#!/usr/bin/env python3
"""Generate dependency-free eBNN Binary-MNIST Golden vectors."""

from __future__ import annotations

import json
import re
import struct
from pathlib import Path


MODEL_DIR = Path(__file__).resolve().parents[1]
DATA_HEADER = MODEL_DIR / "baseline" / "common" / "binary_mnist_data.h"
MODEL_HEADER = MODEL_DIR / "baseline" / "common" / "binary_mnist.h"
SINGLE_TB = MODEL_DIR / "testbench" / "rv32i_ebnn_bdot_tb.v"
REFERENCE_DOC = MODEL_DIR / "baseline" / "docs" / "experiment_flow.md"
OUTPUT_DIR = MODEL_DIR / "vectors" / "generated" / "multiinput"

SAMPLE_COUNT = 20
INPUT_BITS = 28 * 28
INPUT_BYTES = (INPUT_BITS + 7) // 8
POOL_WIDTH = 6
CONV_OUTPUT_BITS = 10 * POOL_WIDTH * POOL_WIDTH


def parse_array(text: str, c_type: str, name: str) -> list[str]:
    match = re.search(
        rf"{re.escape(c_type)}\s+{re.escape(name)}\s*\[[0-9]+\]\s*=\s*\{{(.*?)\}};",
        text,
        flags=re.S,
    )
    if not match:
        raise RuntimeError(f"array not found: {name}")
    return re.findall(r"-?(?:0x[0-9a-fA-F]+|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)", match.group(1))


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def f32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", f32(value)))[0]


def source_bit(data: list[int], index: int) -> int:
    return (data[index >> 3] >> (7 - (index & 7))) & 1


def apply_batch_norm(value: float, bias: float, gamma: float, beta: float, mean: float, std: float) -> float:
    value = f32(value)
    value = f32(value + bias)
    value = f32(value - mean)
    value = f32(value / std)
    value = f32(value * gamma)
    value = f32(value + beta)
    return value


def pack_words(bits: list[int], padded_words: int) -> list[int]:
    words = [0] * padded_words
    for index, bit in enumerate(bits):
        words[index >> 5] |= int(bit) << (index & 31)
    return words


def checksum_words(words: list[int]) -> int:
    value = 2166136261
    for word in words:
        value = ((value ^ word) * 16777619) & 0xFFFFFFFF
    return value


def parse_single_reference() -> tuple[int, int, list[int]]:
    text = SINGLE_TB.read_text(encoding="utf-8")
    prediction = re.search(r"\(dmem\[1\]\s*!=\s*([0-9]+)\)", text)
    checksum = re.search(r"\(dmem\[4\]\s*!=\s*32'h([0-9a-fA-F]+)\)", text)
    score_pairs = re.findall(r"\(dmem\[([0-9]+)\]\s*!=\s*32'h([0-9a-fA-F]+)\)", text)
    score_map = {int(index): int(value, 16) for index, value in score_pairs if 16 <= int(index) <= 25}
    if not prediction or not checksum or sorted(score_map) != list(range(16, 26)):
        raise RuntimeError("single-input reference could not be parsed")
    return int(prediction.group(1)), int(checksum.group(1), 16), [score_map[index] for index in range(16, 26)]


def parse_pc_predictions() -> list[int]:
    text = REFERENCE_DOC.read_text(encoding="utf-8")
    match = re.search(r"predictions=\[([0-9, ]+)\]", text)
    if not match:
        raise RuntimeError("PC reference predictions were not found")
    values = [int(value) for value in match.group(1).split(",")]
    if len(values) != SAMPLE_COUNT:
        raise RuntimeError("PC reference prediction count mismatch")
    return values


class EbnnReference:
    def __init__(self) -> None:
        data_text = DATA_HEADER.read_text(encoding="utf-8")
        model_text = MODEL_HEADER.read_text(encoding="utf-8")
        data = [int(value, 0) for value in parse_array(data_text, "uint8_t", "train_data")]
        self.labels = [int(float(value)) for value in parse_array(data_text, "float", "train_labels")]
        if len(data) != SAMPLE_COUNT * INPUT_BYTES or len(self.labels) != SAMPLE_COUNT:
            raise RuntimeError("Binary-MNIST input or label count mismatch")
        self.inputs = [data[index * INPUT_BYTES:(index + 1) * INPUT_BYTES] for index in range(SAMPLE_COUNT)]

        self.conv_weight = [int(value, 0) for value in parse_array(model_text, "uint8_t", "l_b_conv_pool_bn_bst0_bconv_W")]
        self.conv_bias = self._float_array(model_text, "l_b_conv_pool_bn_bst0_bconv_b")
        self.conv_gamma = self._float_array(model_text, "l_b_conv_pool_bn_bst0_bn_gamma")
        self.conv_beta = self._float_array(model_text, "l_b_conv_pool_bn_bst0_bn_beta")
        self.conv_mean = self._float_array(model_text, "l_b_conv_pool_bn_bst0_bn_mean")
        self.conv_std = self._float_array(model_text, "l_b_conv_pool_bn_bst0_bn_std")
        self.fc_weight = [int(value, 0) for value in parse_array(model_text, "uint8_t", "l_b_linear_bn_softmax1_bl_W")]
        self.fc_bias = self._float_array(model_text, "l_b_linear_bn_softmax1_bl_b")
        self.fc_gamma = self._float_array(model_text, "l_b_linear_bn_softmax1_bn_gamma")
        self.fc_beta = self._float_array(model_text, "l_b_linear_bn_softmax1_bn_beta")
        self.fc_mean = self._float_array(model_text, "l_b_linear_bn_softmax1_bn_mean")
        self.fc_std = self._float_array(model_text, "l_b_linear_bn_softmax1_bn_std")

    @staticmethod
    def _float_array(text: str, name: str) -> list[float]:
        return [f32(float(value)) for value in parse_array(text, "float", name)]

    def infer(self, sample_id: int) -> dict[str, object]:
        input_data = self.inputs[sample_id]
        activation_bits = [0] * CONV_OUTPUT_BITS

        for filter_index in range(10):
            weight_bytes = self.conv_weight[filter_index * 2:(filter_index + 1) * 2]
            weight_bits = [source_bit(weight_bytes, bit) for bit in range(9)]
            for pool_row in range(POOL_WIDTH):
                for pool_col in range(POOL_WIDTH):
                    max_matches = 0
                    for pr in range(3):
                        for pc in range(3):
                            row = pool_row * 4 + pr * 2
                            col = pool_col * 4 + pc * 2
                            window = [
                                source_bit(input_data, (row + kr) * 28 + col + kc)
                                for kr in range(3) for kc in range(3)
                            ]
                            matches = sum(a == b for a, b in zip(window, weight_bits))
                            max_matches = max(max_matches, matches)
                    value = apply_batch_norm(
                        f32(max_matches * 2 - 9),
                        self.conv_bias[filter_index], self.conv_gamma[filter_index],
                        self.conv_beta[filter_index], self.conv_mean[filter_index],
                        self.conv_std[filter_index],
                    )
                    if value >= f32(0.0):
                        activation_bits[filter_index * 36 + pool_row * 6 + pool_col] = 1

        activation_words = pack_words(activation_bits, 12)
        checksum = checksum_words(activation_words)
        scores: list[float] = []
        for output in range(10):
            weight_bytes = self.fc_weight[output * 45:(output + 1) * 45]
            weight_bits = [source_bit(weight_bytes, bit) for bit in range(CONV_OUTPUT_BITS)]
            matches = sum(a == b for a, b in zip(activation_bits, weight_bits))
            score = apply_batch_norm(
                f32(matches * 2 - CONV_OUTPUT_BITS),
                self.fc_bias[output], self.fc_gamma[output], self.fc_beta[output],
                self.fc_mean[output], self.fc_std[output],
            )
            scores.append(score)
        prediction = max(range(10), key=lambda index: scores[index])
        return {
            "sample_id": sample_id,
            "ground_truth_label": self.labels[sample_id],
            "expected_prediction": prediction,
            "activation_words": activation_words,
            "activation_checksum": checksum,
            "scores": scores,
            "score_bits": [f32_bits(score) for score in scores],
        }


def write_hex(path: Path, values: list[int]) -> None:
    path.write_text("".join(f"{value & 0xFFFFFFFF:08x}\n" for value in values), encoding="ascii")


def main() -> None:
    reference = EbnnReference()
    pc_predictions = parse_pc_predictions()
    single_prediction, single_checksum, single_scores = parse_single_reference()
    results = [reference.infer(sample_id) for sample_id in range(SAMPLE_COUNT)]

    gate = results[0]
    prediction_gate = gate["expected_prediction"] == single_prediction
    checksum_gate = gate["activation_checksum"] == single_checksum
    score_gate = gate["score_bits"] == single_scores
    pc_gate = [result["expected_prediction"] for result in results] == pc_predictions
    gate_pass = prediction_gate and checksum_gate and score_gate and pc_gate
    print(
        "EBNN_GOLDEN_GATE "
        f"prediction={'PASS' if prediction_gate else 'FAIL'} "
        f"scores={'PASS' if score_gate else 'FAIL'} "
        f"activation_checksum={'PASS' if checksum_gate else 'FAIL'} "
        f"pc_predictions={'PASS' if pc_gate else 'FAIL'} "
        f"result={'PASS' if gate_pass else 'FAIL'}"
    )
    if not gate_pass:
        raise SystemExit(1)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest = []
    for result in results:
        sample_id = int(result["sample_id"])
        case_dir = OUTPUT_DIR / f"case_{sample_id:02d}"
        case_dir.mkdir(parents=True, exist_ok=True)
        write_hex(case_dir / "expected_scores.hex", result["score_bits"])
        write_hex(case_dir / "expected_activation.hex", result["activation_words"])
        write_hex(case_dir / "expected_checksum.hex", [int(result["activation_checksum"])])
        metadata = {
            "model": "eBNN Binary-MNIST",
            "sample_id": sample_id,
            "dataset_index": sample_id,
            "ground_truth_label": int(result["ground_truth_label"]),
            "expected_prediction": int(result["expected_prediction"]),
            "input_bits": INPUT_BITS,
            "input_bytes": INPUT_BYTES,
            "packing": "source byte MSB-first; activation/weight word LSB-first",
            "activation_checksum": f"{int(result['activation_checksum']):08x}",
            "score_bits": [f"{int(value):08x}" for value in result["score_bits"]],
        }
        (case_dir / "metadata.json").write_text(
            json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        manifest.append(metadata)
        print(
            f"EBNN_VECTOR sample={sample_id} label={metadata['ground_truth_label']} "
            f"prediction={metadata['expected_prediction']} checksum={metadata['activation_checksum']} result=PASS"
        )

    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(f"EBNN_VECTOR_SUMMARY samples={len(manifest)} input_bytes={INPUT_BYTES} result=PASS")


if __name__ == "__main__":
    main()
