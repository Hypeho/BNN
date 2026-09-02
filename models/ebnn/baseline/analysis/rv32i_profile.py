#!/usr/bin/env python3

"""Minimal RV32I interpreter used to collect dynamic instruction counts.

The default 64 KiB data-memory mapping matches the current eBNN hardware. The
memory size and base are configurable so expanded-BRAM FINN images can reuse
the interpreter.
"""

from __future__ import annotations

import argparse
import collections
import csv
import re
import subprocess
from pathlib import Path


def sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def u32(value: int) -> int:
    return value & 0xFFFFFFFF


def load_verilog_words(path: Path) -> dict[int, int]:
    words: dict[int, int] = {}
    address = 0
    for token in path.read_text(encoding="ascii").split():
        if token.startswith("@"):
            address = int(token[1:], 16)
        else:
            words[address] = int(token, 16)
            address += 1
    return words


def load_symbols(elf: Path) -> dict[str, tuple[int, int]]:
    output = subprocess.check_output(
        ["riscv32-unknown-elf-nm", "-S", "--defined-only", str(elf)], text=True
    )
    symbols: dict[str, tuple[int, int]] = {}
    pattern = re.compile(r"^([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\S\s+(.+)$")
    for line in output.splitlines():
        match = pattern.match(line)
        if match:
            symbols[match.group(3)] = (int(match.group(1), 16), int(match.group(2), 16))
    return symbols


class RV32I:
    def __init__(
        self,
        imem: dict[int, int],
        dmem_words: dict[int, int],
        dmem_size: int = 1 << 16,
        dmem_base: int = 0x20000000,
    ):
        if dmem_size <= 0 or dmem_size & (dmem_size - 1):
            raise ValueError("dmem_size must be a positive power of two")
        self.imem = imem
        self.mem = bytearray(dmem_size)
        self.dmem_mask = dmem_size - 1
        self.dmem_base = dmem_base
        for word_address, value in dmem_words.items():
            byte_address = word_address * 4
            for offset in range(4):
                self.mem[(byte_address + offset) & self.dmem_mask] = (value >> (8 * offset)) & 0xFF
        self.reg = [0] * 32
        self.pc = 0
        self.retired = 0
        self.categories: collections.Counter[str] = collections.Counter()
        self.pc_counts: collections.Counter[int] = collections.Counter()

    def read8(self, address: int) -> int:
        return self.mem[(address - self.dmem_base) & self.dmem_mask]

    def read16(self, address: int) -> int:
        return self.read8(address) | (self.read8(address + 1) << 8)

    def read32(self, address: int) -> int:
        return self.read16(address) | (self.read16(address + 2) << 16)

    def write8(self, address: int, value: int) -> None:
        self.mem[(address - self.dmem_base) & self.dmem_mask] = value & 0xFF

    def write16(self, address: int, value: int) -> None:
        self.write8(address, value)
        self.write8(address + 1, value >> 8)

    def write32(self, address: int, value: int) -> None:
        self.write16(address, value)
        self.write16(address + 2, value >> 16)

    def step(self) -> int:
        instruction = self.imem.get(self.pc >> 2)
        if instruction is None:
            raise RuntimeError(f"instruction fetch outside image: pc=0x{self.pc:08x}")

        old_pc = self.pc
        self.pc_counts[old_pc] += 1
        self.retired += 1
        self.pc = u32(self.pc + 4)

        opcode = instruction & 0x7F
        rd = (instruction >> 7) & 0x1F
        funct3 = (instruction >> 12) & 0x7
        rs1 = (instruction >> 15) & 0x1F
        rs2 = (instruction >> 20) & 0x1F
        funct7 = (instruction >> 25) & 0x7F
        a = self.reg[rs1]
        b = self.reg[rs2]
        result: int | None = None

        if opcode == 0x37:  # LUI
            self.categories["lui_auipc"] += 1
            result = instruction & 0xFFFFF000
        elif opcode == 0x17:  # AUIPC
            self.categories["lui_auipc"] += 1
            result = old_pc + (instruction & 0xFFFFF000)
        elif opcode == 0x6F:  # JAL
            self.categories["jal"] += 1
            imm = (
                ((instruction >> 31) & 1) << 20
                | ((instruction >> 12) & 0xFF) << 12
                | ((instruction >> 20) & 1) << 11
                | ((instruction >> 21) & 0x3FF) << 1
            )
            result = old_pc + 4
            self.pc = u32(old_pc + sext(imm, 21))
        elif opcode == 0x67:  # JALR
            self.categories["jalr"] += 1
            result = old_pc + 4
            self.pc = u32((a + sext(instruction >> 20, 12)) & ~1)
        elif opcode == 0x63:  # branches
            self.categories["branch"] += 1
            imm = (
                ((instruction >> 31) & 1) << 12
                | ((instruction >> 7) & 1) << 11
                | ((instruction >> 25) & 0x3F) << 5
                | ((instruction >> 8) & 0xF) << 1
            )
            signed_a = sext(a, 32)
            signed_b = sext(b, 32)
            take = {
                0: a == b,
                1: a != b,
                4: signed_a < signed_b,
                5: signed_a >= signed_b,
                6: a < b,
                7: a >= b,
            }.get(funct3)
            if take is None:
                raise RuntimeError(f"unsupported branch funct3={funct3}")
            if take:
                self.pc = u32(old_pc + sext(imm, 13))
        elif opcode == 0x03:  # loads
            self.categories["load"] += 1
            address = u32(a + sext(instruction >> 20, 12))
            if funct3 == 0:
                result = sext(self.read8(address), 8)
            elif funct3 == 1:
                result = sext(self.read16(address), 16)
            elif funct3 == 2:
                result = self.read32(address)
            elif funct3 == 4:
                result = self.read8(address)
            elif funct3 == 5:
                result = self.read16(address)
            else:
                raise RuntimeError(f"unsupported load funct3={funct3}")
        elif opcode == 0x23:  # stores
            self.categories["store"] += 1
            imm = ((instruction >> 25) << 5) | ((instruction >> 7) & 0x1F)
            address = u32(a + sext(imm, 12))
            if funct3 == 0:
                self.write8(address, b)
            elif funct3 == 1:
                self.write16(address, b)
            elif funct3 == 2:
                self.write32(address, b)
            else:
                raise RuntimeError(f"unsupported store funct3={funct3}")
        elif opcode == 0x13:  # immediate ALU
            self.categories["op_i"] += 1
            imm = sext(instruction >> 20, 12)
            if funct3 == 0:
                self.categories["add_sub"] += 1
                result = a + imm
            elif funct3 == 2:
                result = int(sext(a, 32) < imm)
            elif funct3 == 3:
                result = int(a < u32(imm))
            elif funct3 == 4:
                self.categories["xori"] += 1
                result = a ^ u32(imm)
            elif funct3 == 6:
                self.categories["ori"] += 1
                result = a | u32(imm)
            elif funct3 == 7:
                self.categories["andi"] += 1
                result = a & u32(imm)
            elif funct3 == 1:
                self.categories["shift"] += 1
                result = a << ((instruction >> 20) & 0x1F)
            elif funct3 == 5:
                self.categories["shift"] += 1
                shamt = (instruction >> 20) & 0x1F
                result = sext(a, 32) >> shamt if funct7 == 0x20 else a >> shamt
            else:
                raise RuntimeError(f"unsupported OP-IMM funct3={funct3}")
        elif opcode == 0x33:  # register ALU
            self.categories["op_r"] += 1
            if funct3 == 0:
                self.categories["add_sub"] += 1
                result = a - b if funct7 == 0x20 else a + b
            elif funct3 == 1:
                self.categories["shift"] += 1
                result = a << (b & 0x1F)
            elif funct3 == 2:
                result = int(sext(a, 32) < sext(b, 32))
            elif funct3 == 3:
                result = int(a < b)
            elif funct3 == 4:
                self.categories["xor"] += 1
                result = a ^ b
            elif funct3 == 5:
                self.categories["shift"] += 1
                result = sext(a, 32) >> (b & 0x1F) if funct7 == 0x20 else a >> (b & 0x1F)
            elif funct3 == 6:
                self.categories["or"] += 1
                result = a | b
            elif funct3 == 7:
                self.categories["and"] += 1
                result = a & b
            else:
                raise RuntimeError(f"unsupported OP funct3={funct3}")
        elif opcode == 0x0F:  # FENCE is a no-op in this memory model
            self.categories["fence"] += 1
        else:
            raise RuntimeError(
                f"unsupported instruction 0x{instruction:08x} at pc=0x{old_pc:08x}"
            )

        if result is not None and rd != 0:
            self.reg[rd] = u32(result)
        self.reg[0] = 0
        return instruction


def range_count(counts: collections.Counter[int], start: int, size: int) -> int:
    return sum(count for pc, count in counts.items() if start <= pc < start + size)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--imem", type=Path, required=True)
    parser.add_argument("--dmem", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--max-instructions", type=int, default=20_000_000)
    parser.add_argument("--pc-csv", type=Path)
    args = parser.parse_args()

    cpu = RV32I(load_verilog_words(args.imem), load_verilog_words(args.dmem))
    symbols = load_symbols(args.elf)
    tracked_entries = {
        symbols[name][0]: name
        for name in (
            "bdot",
            "l_b_conv_pool_bn_bst0",
            "l_b_linear_bn_softmax1",
            "ebnn_compute",
            "main",
        )
    }
    active_returns: dict[str, int] = {}
    inclusive_counts: collections.Counter[str] = collections.Counter()
    halted = False
    for _ in range(args.max_instructions):
        old_pc = cpu.pc
        instruction = cpu.imem.get(old_pc >> 2)
        if instruction is None:
            raise RuntimeError(f"instruction fetch outside image: pc=0x{old_pc:08x}")
        if old_pc in tracked_entries:
            name = tracked_entries[old_pc]
            active_returns.setdefault(name, cpu.reg[1])
        for name in active_returns:
            inclusive_counts[name] += 1

        instruction = cpu.step()
        completed = [name for name, return_pc in active_returns.items() if cpu.pc == return_pc]
        for name in completed:
            del active_returns[name]
        if instruction == 0x0000006F:
            halted = True
            break
    if not halted:
        raise RuntimeError(f"timeout after {args.max_instructions} instructions")

    print(f"PROFILE retired={cpu.retired}")
    for key in sorted(cpu.categories):
        print(f"PROFILE {key}={cpu.categories[key]}")
    for name in ("bdot", "l_b_conv_pool_bn_bst0", "l_b_linear_bn_softmax1", "ebnn_compute", "main"):
        start, size = symbols[name]
        print(f"PROFILE function_{name}={range_count(cpu.pc_counts, start, size)}")
        print(f"PROFILE inclusive_{name}={inclusive_counts[name]}")

    bdot_start, _ = symbols["bdot"]
    conv_start, _ = symbols["l_b_conv_pool_bn_bst0"]
    print(f"PROFILE bdot_core={range_count(cpu.pc_counts, bdot_start + 0xB0, 0x4C)}")
    print(f"PROFILE conv_pack={range_count(cpu.pc_counts, conv_start + 0x1AC, 0xAC)}")
    fc_start, _ = symbols["l_b_linear_bn_softmax1"]
    print(f"PROFILE fc_popcount_core={range_count(cpu.pc_counts, fc_start + 0x90, 0x4C)}")
    print(f"PROFILE bdot_calls={cpu.pc_counts[bdot_start]}")
    print(f"PROFILE status=0x{cpu.read32(0x20000000):08x}")
    print(f"PROFILE samples={cpu.read32(0x20000004)}")
    print(f"PROFILE correct={cpu.read32(0x20000008)}")
    print(f"PROFILE prediction={cpu.read32(0x20000040)}")
    print(f"PROFILE expected={cpu.read32(0x20000090)}")

    if args.pc_csv:
        args.pc_csv.parent.mkdir(parents=True, exist_ok=True)
        with args.pc_csv.open("w", newline="", encoding="utf-8") as output:
            writer = csv.writer(output)
            writer.writerow(["pc_hex", "dynamic_count"])
            for pc, count in sorted(cpu.pc_counts.items()):
                writer.writerow([f"0x{pc:08x}", count])


if __name__ == "__main__":
    main()
