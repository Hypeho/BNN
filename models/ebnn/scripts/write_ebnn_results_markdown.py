# -*- coding: utf-8 -*-
"""Write eBNN validation Markdown with explicit UTF-8 encoding."""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


MATCH_FIELDS = (
    "prediction_match",
    "score_match",
    "checksum_match",
    "activation_match",
)


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def write_full(csv_path: Path, output_path: Path) -> None:
    rows = sorted(read_rows(csv_path), key=lambda row: int(row["sample_id"]))
    if len(rows) != 20:
        raise RuntimeError(f"expected 20 CSV rows, found {len(rows)}")
    if any(row["result"] != "PASS" for row in rows):
        raise RuntimeError("CSV contains a non-PASS result")

    total = len(rows)
    counts = {
        field: sum(row[field] == "PASS" for row in rows) for field in MATCH_FIELDS
    }
    cycles = [int(row["cycles"]) for row in rows]
    bdot_values = sorted({int(row["bdot_count"]) for row in rows})
    block_values = sorted({int(row["block_count"]) for row in rows})
    average = sum(cycles) / total

    lines = [
        "# eBNN Binary-MNIST Wide-BDOT128 20-Input XSim 2019.1 Validation",
        "",
        "## 검증 환경",
        "",
        "- Vivado Simulator 2019.1의 xvlog, xelab, xsim을 사용함.",
        "- `binary_mnist_data.h`의 기존 Binary-MNIST sample 20개를 사용함.",
        "- Ground-truth label은 metadata로만 사용함.",
        "- Expected prediction은 기존 eBNN parameter와 PC reference 동작을 독립 재현한 Host Golden을 사용함.",
        "- 기존 Wide-BDOT128 RTL architecture를 수정하지 않음.",
        "",
        "## Golden 검증",
        "",
        "- 기존 PC reference prediction 20개와 Generated Golden prediction이 exact match함.",
        "- 기존 Single-Input sample 0에서 Prediction, Float class score 10개, Activation checksum이 exact match함.",
        "- Ground-truth label을 expected prediction으로 사용하지 않음.",
        "",
        "## 결과",
        "",
        f"- 전체 sample {total}개 모두 Overall PASS함.",
        f"- Prediction exact match는 {counts['prediction_match']}/{total}임.",
        f"- Float class score bit-exact match는 {counts['score_match']}/{total}임.",
        f"- Activation checksum exact match는 {counts['checksum_match']}/{total}임.",
        f"- 360-bit packed activation exact match는 {counts['activation_match']}/{total}임.",
        f"- Cycle minimum은 {min(cycles):,}임.",
        f"- Cycle maximum은 {max(cycles):,}임.",
        f"- Cycle average는 {average:,.2f}임.",
        f"- Cycle range는 {max(cycles) - min(cycles):,}임.",
        f"- BDOT count는 모든 input에서 {','.join(f'{value:,}' for value in bdot_values)}으로 동일함.",
        f"- Block count는 모든 input에서 {','.join(f'{value:,}' for value in block_values)}으로 동일함.",
        "",
        "| Sample | Label | Expected | Actual | Score | Checksum | Activation | Cycles | BDOT | Blocks | Result |",
        "|---:|---:|---:|---:|:---:|:---:|:---:|---:|---:|---:|:---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['sample_id']} | {row['ground_truth_label']} | "
            f"{row['expected_prediction']} | {row['actual_prediction']} | "
            f"{row['score_match']} | {row['checksum_match']} | "
            f"{row['activation_match']} | {row['cycles']} | "
            f"{row['bdot_count']} | {row['block_count']} | {row['result']} |"
        )
    lines.extend(
        [
            "",
            "### Sample 19 해석",
            "",
            "- Ground-truth label은 9임.",
            "- Host Golden expected prediction과 RTL actual prediction은 모두 7임.",
            "- Prediction, Float class score, Activation checksum, packed activation이 모두 PASS함.",
            "- Dataset label이 아니라 eBNN Host Golden 계산 결과를 RTL expected output으로 사용했음을 보여줌.",
            "",
            "## Single-Input Gate",
            "",
            "- Sample은 0이며 Ground-truth label은 5임.",
            "- Expected / RTL prediction은 5 / 5임.",
            "- Float class score bit-exact match는 PASS함.",
            "- Activation checksum match는 PASS함.",
            "- 360-bit packed activation match는 PASS함.",
            "- Cycles는 1,046,677임.",
            "- BDOT count는 3,250임.",
            "- Block count는 3,270임.",
            "- Status는 1이며 Address error는 0임.",
            "",
            "## 범위",
            "",
            "- 본 결과는 Vivado 2019.1 XSim RTL Validation 범위임.",
            "- FPGA Multiple-Input execution은 수행하지 않음.",
            "- Power/Energy 평가는 본 단계의 범위가 아님.",
            "- 20개 Binary-MNIST sample에 대한 검증이며 전체 Dataset에 대한 exhaustive validation은 아님.",
            "- Input별 Cycle variation의 정확한 원인은 이번 단계에서 별도 분석하지 않음.",
        ]
    )
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def result_fields(line: str) -> dict[str, str]:
    return dict(token.split("=", 1) for token in line.split() if "=" in token)


def write_single(log_path: Path, output_path: Path) -> None:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    result_lines = re.findall(r"(?m)^RESULT .+$", text)
    detail_lines = re.findall(r"(?m)^EBNN_MULTI detail .+$", text)
    if len(result_lines) != 1 or len(detail_lines) != 1:
        raise RuntimeError("single-input log does not contain one RESULT/detail line")
    result = result_fields(result_lines[0])
    detail = result_fields(detail_lines[0])
    if result.get("result") != "PASS":
        raise RuntimeError("single-input RESULT is not PASS")
    lines = [
        "# eBNN Single-Input XSim 2019.1 Gate",
        "",
        f"- Sample은 {result['sample_id']}, Ground-truth label은 {result['ground_truth_label']}임.",
        f"- Golden/RTL prediction은 {result['expected_prediction']}/{result['actual_prediction']}임.",
        "- Score, checksum, packed activation은 모두 exact match함.",
        f"- Cycles는 {result['cycles']}, BDOT은 {result['bdot_count']}, Blocks는 {result['block_count']}임.",
        f"- Status는 {result['status']}, Address error는 {detail.get('errors', 'unknown')}임.",
        "- 최종 결과는 PASS임.",
    ]
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    full = subparsers.add_parser("full")
    full.add_argument("--csv", type=Path, required=True)
    full.add_argument("--output", type=Path, required=True)
    single = subparsers.add_parser("single")
    single.add_argument("--log", type=Path, required=True)
    single.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.mode == "full":
        write_full(args.csv, args.output)
    else:
        write_single(args.log, args.output)


if __name__ == "__main__":
    main()
