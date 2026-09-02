#!/usr/bin/env python3
"""Generate bit-exact FINN CNV-W1A1 Golden vectors without PyTorch/Brevitas."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
from pathlib import Path

import numpy as np
import pyarrow.parquet as pq
from PIL import Image


MODEL_DIR = Path(__file__).resolve().parents[1]
DEFAULT_PARAMS = MODEL_DIR / "baseline" / "generated" / "cnv_params.h"
DEFAULT_WIDE_TEMPLATE = MODEL_DIR / "software" / "cnv" / "generated" / "cnv_bdot_params.h"
DEFAULT_SINGLE_TB = MODEL_DIR / "testbench" / "rv32i_cnv_bdot_tb.v"
DEFAULT_SINGLE_SAMPLE = MODEL_DIR / "vectors" / "source" / "cifar10-test-data-class3.npz"
DEFAULT_PARQUET = MODEL_DIR / "work" / "downloads" / "cifar10-test.parquet"
DEFAULT_OUTPUT = MODEL_DIR / "vectors" / "generated" / "multiinput"

LABEL_NAMES = (
    "airplane", "automobile", "bird", "cat", "deer",
    "dog", "frog", "horse", "ship", "truck",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_array(text: str, name: str, dtype: np.dtype) -> np.ndarray:
    pattern = (
        rf"static\s+const\s+\w+_t\s+{re.escape(name)}\s*"
        rf"\[[0-9]+\].*?=\s*\{{(.*?)\}};"
    )
    match = re.search(pattern, text, flags=re.S)
    if not match:
        raise RuntimeError(f"header array not found: {name}")
    tokens = re.findall(r"-?0x[0-9a-fA-F]+|-?[0-9]+", match.group(1))
    return np.asarray([int(token, 0) for token in tokens], dtype=dtype)


def parse_single_tb_reference(path: Path) -> tuple[int, list[int]]:
    text = path.read_text(encoding="utf-8")
    pred_match = re.search(r"\(dmem\[1\]\s*!=\s*(-?[0-9]+)\)", text)
    if not pred_match:
        raise RuntimeError("single-input expected prediction not found in testbench")
    score_matches = re.findall(
        r"\$signed\(dmem\[([0-9]+)\]\)\s*!=\s*(-?[0-9]+)", text)
    score_by_addr = {int(address): int(value) for address, value in score_matches}
    if sorted(score_by_addr) != list(range(16, 26)):
        raise RuntimeError("single-input expected scores 16..25 not found in testbench")
    return int(pred_match.group(1)), [score_by_addr[address] for address in range(16, 26)]


def unpack_words(words: np.ndarray, bit_count: int) -> np.ndarray:
    words = np.asarray(words, dtype=np.uint32).reshape(-1)
    bits = ((words[:, None] >> np.arange(32, dtype=np.uint32)) & 1).astype(bool)
    return bits.reshape(-1)[:bit_count]


def unpack_conv_weights(words: np.ndarray, input_channels: int, output_channels: int) -> np.ndarray:
    words_per_kernel = input_channels // 32
    expected_words = output_channels * 9 * words_per_kernel
    if words.size != expected_words:
        raise RuntimeError(f"conv weight words: expected {expected_words}, got {words.size}")
    arranged = words.reshape(output_channels, 9, words_per_kernel)
    bits = ((arranged[..., None] >> np.arange(32, dtype=np.uint32)) & 1).astype(bool)
    return bits.reshape(output_channels, 3, 3, input_channels)


def unpack_fc_weights(words: np.ndarray, input_bits: int, output_bits: int) -> np.ndarray:
    words_per_neuron = input_bits // 32
    if words.size != output_bits * words_per_neuron:
        raise RuntimeError("FC weight word count mismatch")
    arranged = words.reshape(output_bits, words_per_neuron)
    bits = ((arranged[..., None] >> np.arange(32, dtype=np.uint32)) & 1).astype(bool)
    return bits.reshape(output_bits, input_bits)


def apply_threshold(matches: np.ndarray, thresholds: np.ndarray, polarity_words: np.ndarray) -> np.ndarray:
    output_channels = thresholds.size
    polarity = unpack_words(polarity_words, output_channels)
    ge = matches >= thresholds.reshape((1,) * (matches.ndim - 1) + (output_channels,))
    return ge == polarity.reshape((1,) * (matches.ndim - 1) + (output_channels,))


def pack_activation_words(activation: np.ndarray) -> np.ndarray:
    activation = np.asarray(activation, dtype=bool)
    channels = activation.shape[-1]
    if channels % 32:
        raise RuntimeError(f"activation channels are not word aligned: {channels}")
    pixels = activation.reshape(-1, channels // 32, 32).astype(np.uint32)
    shifts = np.arange(32, dtype=np.uint32)
    return np.bitwise_or.reduce(pixels << shifts, axis=2).reshape(-1).astype(np.uint32)


def word_checksum(activation: np.ndarray) -> int:
    value = 2166136261
    for word in pack_activation_words(activation):
        value = ((value ^ int(word)) * 16777619) & 0xFFFFFFFF
    return value


def quantize_input(raw_hwc: np.ndarray) -> np.ndarray:
    raw = np.asarray(raw_hwc, dtype=np.uint8)
    if raw.shape != (32, 32, 3):
        raise RuntimeError(f"expected HWC (32,32,3), got {raw.shape}")
    normalized = 2.0 * raw.astype(np.float64) / 255.0 - 1.0
    return np.clip(np.rint(normalized * 128.0), -128, 127).astype(np.int8)


class CnvReference:
    def __init__(self, header: Path):
        self.header_path = header
        self.text = header.read_text(encoding="utf-8")
        self.input_q7 = parse_array(self.text, "cnv_input_q7_hwc", np.int8)
        self.w0 = parse_array(self.text, "cnv_w0_i8", np.int8).reshape(64, 3, 3, 3)
        self.threshold0 = parse_array(self.text, "cnv_threshold0", np.int16)
        self.polarity0 = parse_array(self.text, "cnv_polarity0", np.uint32)
        self.conv = []
        for layer, input_channels, output_channels in (
            (1, 64, 64), (2, 64, 128), (3, 128, 128),
            (4, 128, 256), (5, 256, 256),
        ):
            self.conv.append((
                unpack_conv_weights(
                    parse_array(self.text, f"cnv_w{layer}", np.uint32),
                    input_channels, output_channels),
                parse_array(self.text, f"cnv_threshold{layer}", np.uint16),
                parse_array(self.text, f"cnv_polarity{layer}", np.uint32),
            ))
        self.fc = []
        for layer, input_bits, output_bits in ((0, 256, 512), (1, 512, 512)):
            self.fc.append((
                unpack_fc_weights(
                    parse_array(self.text, f"cnv_fc_w{layer}", np.uint32),
                    input_bits, output_bits),
                parse_array(self.text, f"cnv_fc_threshold{layer}", np.uint16),
                parse_array(self.text, f"cnv_fc_polarity{layer}", np.uint32),
            ))
        self.final_weight = unpack_fc_weights(
            parse_array(self.text, "cnv_fc_w2", np.uint32), 512, 10)
        self.single_checksums = parse_array(
            self.text, "cnv_expected_layer_checksums", np.uint32)

    @staticmethod
    def _patches(value: np.ndarray) -> np.ndarray:
        output_h = value.shape[0] - 2
        output_w = value.shape[1] - 2
        return np.concatenate([
            value[ky:ky + output_h, kx:kx + output_w, :]
            for ky in range(3) for kx in range(3)
        ], axis=2)

    def first_conv(self, input_q7: np.ndarray) -> np.ndarray:
        patches = self._patches(input_q7).reshape(-1, 27).astype(np.int32)
        weight = self.w0.reshape(64, 27).astype(np.int32)
        sums = (patches @ weight.T).reshape(30, 30, 64)
        return apply_threshold(sums, self.threshold0.astype(np.int32), self.polarity0)

    @staticmethod
    def binary_conv(
        value: np.ndarray, weight: np.ndarray,
        thresholds: np.ndarray, polarity: np.ndarray,
    ) -> np.ndarray:
        patches = CnvReference._patches(value)
        vector_bits = patches.shape[-1]
        patch_pm = np.where(patches, 1, -1).reshape(-1, vector_bits).astype(np.int16)
        weight_pm = np.where(weight, 1, -1).reshape(weight.shape[0], vector_bits).astype(np.int16)
        dot = patch_pm @ weight_pm.T
        matches = ((dot.astype(np.int32) + vector_bits) // 2).reshape(
            patches.shape[0], patches.shape[1], weight.shape[0])
        return apply_threshold(matches, thresholds.astype(np.int32), polarity)

    @staticmethod
    def pool(value: np.ndarray) -> np.ndarray:
        return (
            value[0::2, 0::2, :] | value[0::2, 1::2, :] |
            value[1::2, 0::2, :] | value[1::2, 1::2, :]
        )

    @staticmethod
    def binary_fc(
        value: np.ndarray, weight: np.ndarray,
        thresholds: np.ndarray, polarity: np.ndarray,
    ) -> np.ndarray:
        input_pm = np.where(value.reshape(-1), 1, -1).astype(np.int16)
        weight_pm = np.where(weight, 1, -1).astype(np.int16)
        vector_bits = input_pm.size
        matches = ((weight_pm @ input_pm).astype(np.int32) + vector_bits) // 2
        return apply_threshold(matches.reshape(1, -1), thresholds.astype(np.int32), polarity)[0]

    def infer(self, raw_hwc: np.ndarray) -> dict[str, object]:
        input_q7 = quantize_input(raw_hwc)
        checksums = []

        value = self.first_conv(input_q7)
        checksums.append(word_checksum(value))
        value = self.binary_conv(value, *self.conv[0])
        checksums.append(word_checksum(value))
        value = self.pool(value)
        checksums.append(word_checksum(value))
        value = self.binary_conv(value, *self.conv[1])
        checksums.append(word_checksum(value))
        value = self.binary_conv(value, *self.conv[2])
        checksums.append(word_checksum(value))
        value = self.pool(value)
        checksums.append(word_checksum(value))
        value = self.binary_conv(value, *self.conv[3])
        checksums.append(word_checksum(value))
        value = self.binary_conv(value, *self.conv[4])
        checksums.append(word_checksum(value))
        value = self.binary_fc(value, *self.fc[0])
        checksums.append(word_checksum(value.reshape(1, 1, -1)))
        value = self.binary_fc(value, *self.fc[1])
        checksums.append(word_checksum(value.reshape(1, 1, -1)))

        input_pm = np.where(value, 1, -1).astype(np.int16)
        weight_pm = np.where(self.final_weight, 1, -1).astype(np.int16)
        matches = ((weight_pm @ input_pm).astype(np.int32) + 512) // 2
        scores = 2 * matches - 512
        prediction = int(np.argmax(scores))
        return {
            "input_q7_hwc": input_q7,
            "checksums": [int(item) for item in checksums],
            "scores": [int(item) for item in scores],
            "prediction": prediction,
        }


def decode_parquet_rows(path: Path) -> list[dict[str, object]]:
    table = pq.read_table(path, columns=["img", "label"])
    result = []
    for dataset_index, row in enumerate(table.to_pylist()):
        image_bytes = row["img"]["bytes"]
        image = np.asarray(Image.open(io.BytesIO(image_bytes)).convert("RGB"), dtype=np.uint8)
        if image.shape != (32, 32, 3):
            raise RuntimeError(f"dataset index {dataset_index}: unexpected image shape {image.shape}")
        result.append({"dataset_index": dataset_index, "label": int(row["label"]), "image": image})
    return result


def select_ten_class_cases(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    selected = [rows[0]]
    used_labels = {int(rows[0]["label"])}
    for row in rows[1:]:
        label = int(row["label"])
        if label not in used_labels:
            selected.append(row)
            used_labels.add(label)
        if len(used_labels) == 10:
            break
    if used_labels != set(range(10)):
        raise RuntimeError(f"10-class coverage failed: labels={sorted(used_labels)}")
    return selected


def format_c_array(values: np.ndarray, ctype: str, per_line: int) -> str:
    flat = np.asarray(values).reshape(-1)
    lines = []
    for start in range(0, flat.size, per_line):
        chunk = flat[start:start + per_line]
        if ctype == "uint32_t":
            lines.append("    " + ", ".join(f"0x{int(v) & 0xffffffff:08x}u" for v in chunk) + ",")
        else:
            lines.append("    " + ", ".join(str(int(v)) for v in chunk) + ",")
    return "\n".join(lines)


def replace_header_array(text: str, name: str, values: np.ndarray, ctype: str, per_line: int) -> str:
    pattern = (
        rf"(static\s+const\s+{re.escape(ctype)}\s+{re.escape(name)}\s*"
        rf"\[[0-9]+\].*?=\s*\{{)(.*?)(\}};)"
    )
    replacement = rf"\1\n{format_c_array(values, ctype, per_line)}\n\3"
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError(f"failed to replace header array: {name}")
    return updated


def write_case(
    output_root: Path, sample_id: int, row: dict[str, object],
    golden: dict[str, object], wide_template: str,
) -> dict[str, object]:
    case_dir = output_root / f"case_{sample_id:02d}"
    generated_dir = case_dir / "generated"
    generated_dir.mkdir(parents=True, exist_ok=True)
    raw_hwc = np.asarray(row["image"], dtype=np.uint8)
    raw_chw = raw_hwc.transpose(2, 0, 1)[None, ...]
    np.savez_compressed(case_dir / "input.npz", arr_0=raw_chw)

    input_q7 = np.asarray(golden["input_q7_hwc"], dtype=np.int8)
    (case_dir / "input_q7_hwc.hex").write_text(
        "".join(f"{int(value) & 0xff:02x}\n" for value in input_q7.reshape(-1)), encoding="ascii")
    (case_dir / "expected_scores.hex").write_text(
        "\n".join(f"{value & 0xffffffff:08x}" for value in golden["scores"]) + "\n",
        encoding="ascii")
    (case_dir / "expected_checksums.hex").write_text(
        "\n".join(f"{value:08x}" for value in golden["checksums"]) + "\n", encoding="ascii")

    header = re.sub(
        r"#define\s+CNV_EXPECTED_CLASS\s+-?[0-9]+",
        f"#define CNV_EXPECTED_CLASS {golden['prediction']}",
        wide_template,
        count=1,
    )
    header = replace_header_array(header, "cnv_input_q7_hwc", input_q7, "int8_t", 24)
    header = replace_header_array(
        header, "cnv_expected_layer_checksums",
        np.asarray(golden["checksums"], dtype=np.uint32), "uint32_t", 10)
    (generated_dir / "cnv_bdot_params.h").write_text(header, encoding="utf-8")

    metadata = {
        "model": "FINN_CNV_W1A1_Wide_BDOT128",
        "sample_id": sample_id,
        "dataset_index": int(row["dataset_index"]),
        "ground_truth_label": int(row["label"]),
        "ground_truth_name": LABEL_NAMES[int(row["label"])],
        "expected_prediction": int(golden["prediction"]),
        "scores": golden["scores"],
        "checksums": [f"0x{value:08x}" for value in golden["checksums"]],
        "input_shape_nchw": [1, 3, 32, 32],
        "input_layout_firmware": "HWC int8 Q1.7",
        "input_quantization": "clip(round((2 * uint8 / 255 - 1) * 128), -128, 127)",
    }
    (case_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--params-header", type=Path, default=DEFAULT_PARAMS)
    parser.add_argument("--wide-template", type=Path, default=DEFAULT_WIDE_TEMPLATE)
    parser.add_argument("--single-testbench", type=Path, default=DEFAULT_SINGLE_TB)
    parser.add_argument("--single-sample", type=Path, default=DEFAULT_SINGLE_SAMPLE)
    parser.add_argument("--dataset-parquet", type=Path, default=DEFAULT_PARQUET)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    for path in (
        args.params_header, args.wide_template, args.single_testbench,
        args.single_sample, args.dataset_parquet,
    ):
        if not path.is_file():
            raise FileNotFoundError(path)

    reference = CnvReference(args.params_header)
    rows = decode_parquet_rows(args.dataset_parquet)
    single_raw = np.load(args.single_sample)["arr_0"]
    if single_raw.shape != (1, 3, 32, 32) or single_raw.dtype != np.uint8:
        raise RuntimeError(f"unexpected FINN qnn sample: {single_raw.shape} {single_raw.dtype}")
    single_hwc = single_raw[0].transpose(1, 2, 0)
    dataset_input_match = np.array_equal(single_hwc, rows[0]["image"])
    packed_input_match = np.array_equal(
        quantize_input(single_hwc).reshape(-1), reference.input_q7.reshape(-1))
    expected_prediction, expected_scores = parse_single_tb_reference(args.single_testbench)
    single_golden = reference.infer(single_hwc)
    prediction_match = single_golden["prediction"] == expected_prediction
    score_match = single_golden["scores"] == expected_scores
    checksum_match = single_golden["checksums"] == [int(v) for v in reference.single_checksums]
    gate_pass = all((dataset_input_match, packed_input_match, prediction_match, score_match, checksum_match))

    args.output_root.mkdir(parents=True, exist_ok=True)
    gate = {
        "dataset_index": 0,
        "ground_truth_label": int(rows[0]["label"]),
        "dataset_input_exact_match": dataset_input_match,
        "packed_input_exact_match": packed_input_match,
        "expected_prediction": expected_prediction,
        "generated_prediction": single_golden["prediction"],
        "prediction_exact_match": prediction_match,
        "expected_scores": expected_scores,
        "generated_scores": single_golden["scores"],
        "scores_exact_match": score_match,
        "expected_checksums": [f"0x{int(v):08x}" for v in reference.single_checksums],
        "generated_checksums": [f"0x{v:08x}" for v in single_golden["checksums"]],
        "intermediate_checksums_exact_match": checksum_match,
        "result": "PASS" if gate_pass else "FAIL",
    }
    (args.output_root / "golden_gate.json").write_text(
        json.dumps(gate, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(
        "CNV_GOLDEN_GATE "
        f"dataset_input={'PASS' if dataset_input_match else 'FAIL'} "
        f"packed_input={'PASS' if packed_input_match else 'FAIL'} "
        f"prediction={'PASS' if prediction_match else 'FAIL'} "
        f"scores={'PASS' if score_match else 'FAIL'} "
        f"checksums={'PASS' if checksum_match else 'FAIL'} "
        f"result={'PASS' if gate_pass else 'FAIL'}"
    )
    if not gate_pass:
        raise SystemExit(1)

    selected = select_ten_class_cases(rows)
    template = args.wide_template.read_text(encoding="utf-8")
    manifest = []
    for sample_id, row in enumerate(selected):
        golden = reference.infer(np.asarray(row["image"], dtype=np.uint8))
        metadata = write_case(args.output_root, sample_id, row, golden, template)
        manifest.append(metadata)
        print(
            f"CNV_VECTOR sample={sample_id} dataset_index={metadata['dataset_index']} "
            f"label={metadata['ground_truth_label']} prediction={metadata['expected_prediction']} "
            f"scores={','.join(str(v) for v in metadata['scores'])} result=PASS"
        )

    source_manifest = {
        "finn_qnn_sample": {
            "path": str(args.single_sample),
            "sha256": sha256(args.single_sample),
            "url": "https://raw.githubusercontent.com/Xilinx/finn/main/src/finn/qnn-data/cifar10/cifar10-test-data-class3.npz",
        },
        "cifar10_test_parquet": {
            "path": str(args.dataset_parquet),
            "sha256": sha256(args.dataset_parquet),
            "url": "https://huggingface.co/datasets/uoft-cs/cifar10/resolve/refs%2Fconvert%2Fparquet/plain_text/test/0000.parquet",
            "source_dataset": "CIFAR-10 test split",
        },
        "parameter_header": {
            "path": str(args.params_header),
            "sha256": sha256(args.params_header),
        },
        "cases": manifest,
    }
    (args.output_root / "manifest.json").write_text(
        json.dumps(source_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"CNV_VECTOR_SUMMARY samples={len(manifest)} classes={len(set(m['ground_truth_label'] for m in manifest))} result=PASS")


if __name__ == "__main__":
    main()
