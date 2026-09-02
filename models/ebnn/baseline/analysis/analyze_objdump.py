#!/usr/bin/env python3

"""Summarize static RV32I instruction composition from GNU objdump output."""

from __future__ import annotations

import argparse
import collections
import re
from pathlib import Path


LABEL_RE = re.compile(r"^[0-9a-fA-F]+ <([^>]+)>:$")
INST_RE = re.compile(
    r"^\s*[0-9a-fA-F]+:\s+[0-9a-fA-F]+\s+([.a-zA-Z0-9_]+)(?:\s|$)"
)


def category(mnemonic: str) -> str:
    if mnemonic in {"lb", "lbu", "lh", "lhu", "lw"}:
        return "load"
    if mnemonic in {"sb", "sh", "sw"}:
        return "store"
    if mnemonic in {"beq", "bne", "blt", "bge", "bltu", "bgeu", "blez", "bgtz"}:
        return "branch"
    if mnemonic in {"jal", "jalr", "j", "jr", "ret", "call", "tail"}:
        return "jump_call"
    if mnemonic in {"xor", "xori", "not"}:
        return "xnor_support"
    if mnemonic in {"and", "andi", "or", "ori"}:
        return "logic"
    if mnemonic in {"sll", "slli", "srl", "srli", "sra", "srai"}:
        return "shift"
    if mnemonic in {"add", "addi", "sub", "mv", "li", "lui", "auipc"}:
        return "integer_arithmetic"
    if mnemonic in {"slt", "slti", "sltu", "sltiu", "seqz", "snez"}:
        return "compare"
    return "other"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("objdump", type=Path)
    args = parser.parse_args()

    functions: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    current = "<none>"
    for raw_line in args.objdump.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        label = LABEL_RE.match(line)
        if label:
            current = label.group(1)
            continue
        inst = INST_RE.match(raw_line)
        if inst:
            functions[current][inst.group(1)] += 1

    selected = [
        "bdot",
        "l_b_conv_pool_bn_bst0",
        "l_b_linear_bn_softmax1",
        "ebnn_compute",
        "main",
    ]
    all_counts: collections.Counter[str] = collections.Counter()
    for counts in functions.values():
        all_counts.update(counts)

    print("scope,total,load,store,branch,jump_call,xnor_support,logic,shift,integer_arithmetic,compare,other")
    for name in ["ALL", *selected]:
        counts = all_counts if name == "ALL" else functions[name]
        cats: collections.Counter[str] = collections.Counter()
        for mnemonic, count in counts.items():
            cats[category(mnemonic)] += count
        total = sum(counts.values())
        values = [
            name,
            str(total),
            *[
                str(cats[key])
                for key in (
                    "load",
                    "store",
                    "branch",
                    "jump_call",
                    "xnor_support",
                    "logic",
                    "shift",
                    "integer_arithmetic",
                    "compare",
                    "other",
                )
            ],
        ]
        print(",".join(values))

    print("\n[bdot mnemonics]")
    for mnemonic, count in functions["bdot"].most_common():
        print(f"{mnemonic},{count}")


if __name__ == "__main__":
    main()

