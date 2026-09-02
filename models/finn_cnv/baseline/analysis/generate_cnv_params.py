#!/usr/bin/env python3

"""Generate a packed RV32I parameter image for Brevitas/FINN CNV-W1A1."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

from brevitas_examples.bnn_pynq.models import model_with_cfg


CONV_MODULES = ((1, 2), (4, 5), (8, 9), (11, 12), (15, 16), (18, 19))
FC_MODULES = ((0, 1), (3, 4))


def pack_positive(values: np.ndarray) -> np.ndarray:
    flat = np.asarray(values).reshape(-1)
    words = np.zeros((flat.size + 31) // 32, dtype=np.uint32)
    for index, value in enumerate(flat):
        if value > 0:
            words[index // 32] |= np.uint32(1 << (index % 32))
    return words


def emit_u32(name: str, values: np.ndarray, output: list[str]) -> None:
    flat = np.asarray(values, dtype=np.uint32).reshape(-1)
    output.append(f"static const uint32_t {name}[{flat.size}] __attribute__((aligned(4))) = {{")
    for start in range(0, flat.size, 8):
        output.append("  " + ", ".join(f"0x{int(x):08x}u" for x in flat[start:start + 8]) + ",")
    output.append("};")


def emit_u16(name: str, values: np.ndarray, output: list[str]) -> None:
    flat = np.asarray(values, dtype=np.uint16).reshape(-1)
    output.append(f"static const uint16_t {name}[{flat.size}] __attribute__((aligned(4))) = {{")
    for start in range(0, flat.size, 16):
        output.append("  " + ", ".join(str(int(x)) for x in flat[start:start + 16]) + ",")
    output.append("};")


def emit_i16(name: str, values: np.ndarray, output: list[str]) -> None:
    flat = np.asarray(values, dtype=np.int16).reshape(-1)
    output.append(f"static const int16_t {name}[{flat.size}] __attribute__((aligned(4))) = {{")
    for start in range(0, flat.size, 16):
        output.append("  " + ", ".join(str(int(x)) for x in flat[start:start + 16]) + ",")
    output.append("};")


def emit_i8(name: str, values: np.ndarray, output: list[str]) -> None:
    flat = np.asarray(values, dtype=np.int8).reshape(-1)
    output.append(f"static const int8_t {name}[{flat.size}] __attribute__((aligned(4))) = {{")
    for start in range(0, flat.size, 24):
        output.append("  " + ", ".join(str(int(x)) for x in flat[start:start + 24]) + ",")
    output.append("};")


def bn_coefficients(bn: torch.nn.Module) -> tuple[np.ndarray, np.ndarray]:
    gamma = bn.weight.detach().cpu().numpy().astype(np.float64)
    beta = bn.bias.detach().cpu().numpy().astype(np.float64)
    mean = bn.running_mean.detach().cpu().numpy().astype(np.float64)
    variance = bn.running_var.detach().cpu().numpy().astype(np.float64)
    inv_std = 1.0 / np.sqrt(variance + float(bn.eps))
    return gamma * inv_std, beta - gamma * mean * inv_std


def binary_thresholds(bn: torch.nn.Module, input_bits: int) -> tuple[np.ndarray, np.ndarray]:
    alpha, offset = bn_coefficients(bn)
    matches = np.arange(input_bits + 1, dtype=np.float64)
    dots = 2.0 * matches - input_bits
    thresholds = np.empty(alpha.size, dtype=np.uint16)
    polarity = np.empty(alpha.size, dtype=np.bool_)
    for index, (a, b) in enumerate(zip(alpha, offset)):
        positive = a * dots + b > 0.0
        if a >= 0.0:
            polarity[index] = True
            locations = np.flatnonzero(positive)
        else:
            polarity[index] = False
            locations = np.flatnonzero(~positive)
        thresholds[index] = int(locations[0]) if locations.size else input_bits + 1
    return thresholds, pack_positive(np.where(polarity, 1, -1))


def int8_thresholds(bn: torch.nn.Module, max_abs_sum: int) -> tuple[np.ndarray, np.ndarray]:
    alpha, offset = bn_coefficients(bn)
    sums = np.arange(-max_abs_sum, max_abs_sum + 1, dtype=np.float64)
    thresholds = np.empty(alpha.size, dtype=np.int16)
    polarity = np.empty(alpha.size, dtype=np.bool_)
    for index, (a, b) in enumerate(zip(alpha, offset)):
        positive = a * (sums / 128.0) + b > 0.0
        if a >= 0.0:
            polarity[index] = True
            locations = np.flatnonzero(positive)
        else:
            polarity[index] = False
            locations = np.flatnonzero(~positive)
        thresholds[index] = int(sums[locations[0]]) if locations.size else max_abs_sum + 1
    return thresholds, pack_positive(np.where(polarity, 1, -1))


def pack_conv_weight(weight: np.ndarray) -> np.ndarray:
    out_ch, in_ch, kh, kw = weight.shape
    result = []
    for oc in range(out_ch):
        for ky in range(kh):
            for kx in range(kw):
                result.extend(pack_positive(weight[oc, :, ky, kx]))
    return np.asarray(result, dtype=np.uint32)


def pack_fc_weight(weight: np.ndarray) -> np.ndarray:
    return np.concatenate([pack_positive(weight[oc]) for oc in range(weight.shape[0])])


def pack_activation_hwc(tensor: torch.Tensor) -> np.ndarray:
    array = tensor.detach().cpu().numpy()[0]
    if array.ndim == 3:
        array = np.transpose(array, (1, 2, 0))
        channels = array.shape[-1]
        result = []
        for pixel in array.reshape(-1, channels):
            result.extend(pack_positive(pixel))
        return np.asarray(result, dtype=np.uint32)
    return pack_positive(array.reshape(-1))


def word_checksum(words: np.ndarray) -> int:
    value = 2166136261
    for word in np.asarray(words, dtype=np.uint32).reshape(-1):
        value ^= int(word)
        value = (value * 16777619) & 0xFFFFFFFF
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--sample", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    model, _ = model_with_cfg("cnv_1w1a", False)
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model.load_state_dict(state, strict=True)
    model.eval()
    raw = np.load(args.sample)["arr_0"]
    sample = torch.from_numpy(raw).float() / 255.0
    with torch.no_grad():
        quant_input = model.conv_features[0](2.0 * sample - torch.tensor([1.0]))
        logits = model(sample).reshape(-1)
        layer_checksums = []
        value = 2.0 * sample - torch.tensor([1.0])
        for index, module in enumerate(model.conv_features):
            value = module(value)
            if index in (3, 6, 7, 10, 13, 14, 17, 20):
                layer_checksums.append(word_checksum(pack_activation_hwc(value)))
        value = value.view(value.shape[0], -1)
        for index, module in enumerate(model.linear_features):
            value = module(value)
            if index in (2, 5):
                layer_checksums.append(word_checksum(pack_activation_hwc(value)))
    expected = int(torch.argmax(logits).item())
    qint = torch.round(quant_input * 128.0).to(torch.int8).cpu().numpy()[0]
    qint_hwc = np.transpose(qint, (1, 2, 0))

    output = [
        "#ifndef FINN_CNV_PARAMS_H",
        "#define FINN_CNV_PARAMS_H",
        "#include <stdint.h>",
        f"#define CNV_EXPECTED_CLASS {expected}",
    ]
    emit_i8("cnv_input_q7_hwc", qint_hwc, output)

    for layer, (conv_index, bn_index) in enumerate(CONV_MODULES):
        conv = model.conv_features[conv_index]
        bn = model.conv_features[bn_index]
        weight = conv.quant_weight().value.detach().cpu().numpy()
        if layer == 0:
            first_hwc = np.transpose(weight, (0, 2, 3, 1))
            emit_i8("cnv_w0_i8", np.where(first_hwc > 0, 1, -1), output)
            threshold, polarity = int8_thresholds(bn, 27 * 128)
            emit_i16("cnv_threshold0", threshold, output)
        else:
            emit_u32(f"cnv_w{layer}", pack_conv_weight(weight), output)
            threshold, polarity = binary_thresholds(bn, weight.shape[1] * 9)
            emit_u16(f"cnv_threshold{layer}", threshold, output)
        emit_u32(f"cnv_polarity{layer}", polarity, output)

    for fc_layer, (linear_index, bn_index) in enumerate(FC_MODULES):
        linear = model.linear_features[linear_index]
        bn = model.linear_features[bn_index]
        weight = linear.quant_weight().value.detach().cpu().numpy()
        emit_u32(f"cnv_fc_w{fc_layer}", pack_fc_weight(weight), output)
        threshold, polarity = binary_thresholds(bn, weight.shape[1])
        emit_u16(f"cnv_fc_threshold{fc_layer}", threshold, output)
        emit_u32(f"cnv_fc_polarity{fc_layer}", polarity, output)

    final = model.linear_features[6]
    final_weight = final.quant_weight().value.detach().cpu().numpy()
    emit_u32("cnv_fc_w2", pack_fc_weight(final_weight), output)
    norm = model.linear_features[7]
    norm_gain = float((norm.weight / torch.sqrt(norm.running_var + norm.eps)).item())
    output.append(f"#define CNV_FINAL_GAIN_POSITIVE {1 if norm_gain > 0 else 0}")
    emit_u32("cnv_expected_layer_checksums", np.asarray(layer_checksums, dtype=np.uint32), output)
    output.extend(["#endif", ""])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(output), encoding="utf-8")
    print(f"PyTorch prediction={expected} logits={logits.tolist()}")
    print(f"quant_input_range={int(qint.min())}..{int(qint.max())}")
    print(f"final_norm_gain={norm_gain}")
    print("layer_checksums=" + ",".join(f"0x{x:08x}" for x in layer_checksums))
    print(f"generated={args.output} bytes={args.output.stat().st_size}")


if __name__ == "__main__":
    main()
