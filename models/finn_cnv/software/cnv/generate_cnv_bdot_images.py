#!/usr/bin/env python3
"""Build aligned Wide-BDOT128 weight images and a compact CNV parameter header."""

import hashlib
import json
import re
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[2]
SOURCE_HEADER = PROJECT_DIR.parent / "260719_FINN_CNV_RV32I/generated/cnv_params.h"
OUTPUT_DIR = Path(__file__).resolve().parent / "generated"

ACT0_BASE = 0x30000000
ACT1_BASE = 0x30010000
WEIGHT_BASE = 0x40000000
ACT_WORDS = 8192
WEIGHT_WORDS = 102400


def parse_array(text, ctype, name):
    pattern = (
        rf"static\s+const\s+{re.escape(ctype)}\s+{re.escape(name)}"
        rf"\s*\[[0-9]+\].*?=\s*\{{(.*?)\}};"
    )
    match = re.search(pattern, text, flags=re.S)
    if not match:
        raise RuntimeError(f"array {name} was not found")
    tokens = re.findall(r"-?0x[0-9a-fA-F]+|-?[0-9]+", match.group(1))
    return [int(token, 0) for token in tokens]


def write_hex(path, words):
    path.write_text("".join(f"{word & 0xffffffff:08x}\n" for word in words))


def write_c_array(handle, ctype, name, values, per_line=12):
    handle.write(
        f"static const {ctype} {name}[{len(values)}] "
        "__attribute__((aligned(4))) = {\n"
    )
    for index in range(0, len(values), per_line):
        chunk = values[index:index + per_line]
        if ctype == "uint32_t":
            rendered = ", ".join(f"0x{value & 0xffffffff:08x}u" for value in chunk)
        else:
            rendered = ", ".join(str(value) for value in chunk)
        handle.write(f"    {rendered},\n")
    handle.write("};\n\n")


def main():
    text = SOURCE_HEADER.read_text()
    binary_layers = [
        ("W1", "cnv_w1", 64, 64),
        ("W2", "cnv_w2", 64, 128),
        ("W3", "cnv_w3", 128, 128),
        ("W4", "cnv_w4", 128, 256),
        ("W5", "cnv_w5", 256, 256),
    ]
    fc_layers = [
        ("FC0", "cnv_fc_w0", 256, 512),
        ("FC1", "cnv_fc_w1", 512, 512),
        ("FC2", "cnv_fc_w2", 512, 10),
    ]

    image = []
    metadata = []
    macros = []
    for label, name, input_ch, output_ch in binary_layers:
        source = parse_array(text, "uint32_t", name)
        source_words = input_ch // 32
        kernel_words = max(4, source_words)
        expected = output_ch * 9 * source_words
        if len(source) != expected:
            raise RuntimeError(f"{name}: expected {expected} words, got {len(source)}")
        while len(image) % 4:
            image.append(0)
        offset = len(image)
        for oc in range(output_ch):
            for kernel in range(9):
                begin = (oc * 9 + kernel) * source_words
                image.extend(source[begin:begin + source_words])
                image.extend([0] * (kernel_words - source_words))
        macros.append((label, offset * 4, kernel_words * 4))
        metadata.append({
            "name": label,
            "offset_bytes": offset * 4,
            "kernel_stride_bytes": kernel_words * 4,
            "input_bits": input_ch,
            "outputs": output_ch,
        })

    for label, name, input_bits, output_bits in fc_layers:
        source = parse_array(text, "uint32_t", name)
        source_words = input_bits // 32
        if len(source) != output_bits * source_words:
            raise RuntimeError(f"{name}: unexpected word count {len(source)}")
        while len(image) % 4:
            image.append(0)
        offset = len(image)
        image.extend(source)
        macros.append((label, offset * 4, source_words * 4))
        metadata.append({
            "name": label,
            "offset_bytes": offset * 4,
            "neuron_stride_bytes": source_words * 4,
            "input_bits": input_bits,
            "outputs": output_bits,
        })

    if len(image) > WEIGHT_WORDS:
        raise RuntimeError(f"CNV image uses {len(image) * 4} bytes, exceeds 400 KiB")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    weight_path = OUTPUT_DIR / "weight_128.hex"
    act0_path = OUTPUT_DIR / "activation0.hex"
    act1_path = OUTPUT_DIR / "activation1.hex"
    write_hex(weight_path, image + [0] * (WEIGHT_WORDS - len(image)))
    write_hex(act0_path, [0] * ACT_WORDS)
    write_hex(act1_path, [0] * ACT_WORDS)

    header_path = OUTPUT_DIR / "cnv_bdot_params.h"
    with header_path.open("w") as handle:
        handle.write("#ifndef CNV_BDOT_PARAMS_H\n#define CNV_BDOT_PARAMS_H\n")
        handle.write("#include <stdint.h>\n\n")
        handle.write("#define CNV_EXPECTED_CLASS 3\n")
        handle.write("#define CNV_FINAL_GAIN_POSITIVE 1\n")
        handle.write(f"#define CNV_ACT0_BASE 0x{ACT0_BASE:08x}u\n")
        handle.write(f"#define CNV_ACT1_BASE 0x{ACT1_BASE:08x}u\n")
        handle.write(f"#define CNV_WEIGHT_BASE 0x{WEIGHT_BASE:08x}u\n")
        for label, offset, stride in macros:
            handle.write(f"#define CNV_{label}_BASE (CNV_WEIGHT_BASE + 0x{offset:05x}u)\n")
            handle.write(f"#define CNV_{label}_STRIDE {stride}u\n")
        handle.write("\n")
        write_c_array(handle, "int8_t", "cnv_input_q7_hwc", parse_array(text, "int8_t", "cnv_input_q7_hwc"), 24)
        write_c_array(handle, "int8_t", "cnv_w0_i8", parse_array(text, "int8_t", "cnv_w0_i8"), 24)
        write_c_array(handle, "int16_t", "cnv_threshold0", parse_array(text, "int16_t", "cnv_threshold0"), 16)
        write_c_array(handle, "uint32_t", "cnv_polarity0", parse_array(text, "uint32_t", "cnv_polarity0"), 8)
        for layer in range(1, 6):
            write_c_array(handle, "uint16_t", f"cnv_threshold{layer}", parse_array(text, "uint16_t", f"cnv_threshold{layer}"), 16)
            write_c_array(handle, "uint32_t", f"cnv_polarity{layer}", parse_array(text, "uint32_t", f"cnv_polarity{layer}"), 8)
        for layer in range(2):
            write_c_array(handle, "uint16_t", f"cnv_fc_threshold{layer}", parse_array(text, "uint16_t", f"cnv_fc_threshold{layer}"), 16)
            write_c_array(handle, "uint32_t", f"cnv_fc_polarity{layer}", parse_array(text, "uint32_t", f"cnv_fc_polarity{layer}"), 8)
        write_c_array(handle, "uint32_t", "cnv_expected_layer_checksums", parse_array(text, "uint32_t", "cnv_expected_layer_checksums"), 10)
        handle.write("#endif\n")

    hashes = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (weight_path, act0_path, act1_path, header_path)
    }
    result = {
        "source": str(SOURCE_HEADER),
        "weight_bytes_used": len(image) * 4,
        "weight_bytes_allocated": WEIGHT_WORDS * 4,
        "layers": metadata,
        "sha256": hashes,
    }
    (OUTPUT_DIR / "cnv_bdot_metadata.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"CNV BDOT image PASS weight_bytes_used={len(image) * 4}")
    for layer in metadata:
        print(layer)


if __name__ == "__main__":
    main()
