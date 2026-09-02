#!/usr/bin/env python3

import argparse
from pathlib import Path


def parse_hex(path):
    words = {}
    index = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        for token in line.split():
            if token.startswith("@"):
                index = int(token[1:], 16)
            else:
                words[index] = int(token, 16) & 0xFFFFFFFF
                index += 1
    return words


def emit_array(name, words, out_path, cols):
    if words:
        base = min(words)
        limit = max(words)
        array = [words.get(i, 0) for i in range(base, limit + 1)]
    else:
        array = []

    lines = [f"static const uint32_t {name}[] = {{"]
    for i in range(0, len(array), cols):
      chunk = array[i:i + cols]
      lines.append("  " + " ".join(f"0x{value:08X}U," for value in chunk))
    lines.append("};")
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cols", default=4, type=int)
    args = parser.parse_args()

    emit_array(args.name, parse_hex(args.path), args.out, args.cols)


if __name__ == "__main__":
    main()
