#!/usr/bin/env python3

from __future__ import annotations

import argparse
import collections
import importlib.util
import subprocess
from pathlib import Path


def load_profiler(path: Path):
    spec = importlib.util.spec_from_file_location("rv32i_profile", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def symbols(elf: Path) -> dict[str, tuple[int, int]]:
    output = subprocess.check_output(
        ["riscv32-unknown-elf-nm", "-S", "--defined-only", str(elf)], text=True
    )
    result = {}
    for line in output.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4:
            result[fields[3]] = (int(fields[0], 16), int(fields[1], 16))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profiler", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--imem", type=Path, required=True)
    parser.add_argument("--dmem", type=Path, required=True)
    parser.add_argument("--max-instructions", type=int, default=20_000_000)
    args = parser.parse_args()
    profiler = load_profiler(args.profiler)
    cpu = profiler.RV32I(
        profiler.load_verilog_words(args.imem),
        profiler.load_verilog_words(args.dmem),
        dmem_size=1 << 20,
    )
    sym = symbols(args.elf)
    counts: collections.Counter[int] = collections.Counter()
    for _ in range(args.max_instructions):
        old_pc = cpu.pc
        instruction = cpu.imem.get(old_pc >> 2)
        if instruction is None:
            raise RuntimeError(f"instruction fetch outside image: 0x{old_pc:08x}")
        counts[old_pc] += 1
        cpu.step()
        if instruction == 0x0000006F:
            break
    else:
        raise RuntimeError("instruction limit reached")

    print(f"PROFILE retired={cpu.retired}")
    for key in sorted(cpu.categories):
        print(f"PROFILE {key}={cpu.categories[key]}")
    for name in ("xnor_match32", "binary_threshold_layer", "finn_lfc_inference", "main"):
        symbol_name = next(key for key in sym if key == name or key.startswith(name + "."))
        start, size = sym[symbol_name]
        dynamic = sum(value for pc, value in counts.items() if start <= pc < start + size)
        print(f"PROFILE function_{name}={dynamic}")
    print(f"PROFILE status={cpu.read32(0x20000000)}")
    print(f"PROFILE prediction={cpu.read32(0x20000004)}")
    print(f"PROFILE expected={cpu.read32(0x20000008)}")
    print(f"PROFILE correct={cpu.read32(0x2000000c)}")
    print("PROFILE scores=" + ",".join(str(profiler.sext(cpu.read32(0x20000040 + 4*i), 32)) for i in range(10)))


if __name__ == "__main__":
    main()
