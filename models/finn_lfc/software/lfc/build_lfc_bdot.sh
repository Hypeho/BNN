#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_LFC_DIR="$(cd "${PROJECT_DIR}/../260719_FINN_LFC_RV32I" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build/bdot128"
ELF_FILE="${BUILD_DIR}/finn_lfc_bdot128.elf"

python3 "${SCRIPT_DIR}/generate_lfc_bdot_images.py"
mkdir -p "${BUILD_DIR}"

riscv32-unknown-elf-gcc \
  -march=rv32i -mabi=ilp32 -O2 -g0 \
  -ffunction-sections -fdata-sections -fno-builtin -nostdlib \
  -I"${SCRIPT_DIR}" \
  -Wl,--gc-sections \
  -Wl,-Map,"${BUILD_DIR}/finn_lfc_bdot128.map" \
  -T "${SCRIPT_DIR}/memory_bdot.ld" \
  "${SOURCE_LFC_DIR}/RISC-V/crt0.S" \
  "${SCRIPT_DIR}/main_finn_lfc_bdot.c" \
  -lgcc -o "${ELF_FILE}"

riscv32-unknown-elf-size "${ELF_FILE}"
riscv32-unknown-elf-objdump -d -S "${ELF_FILE}" \
  > "${BUILD_DIR}/finn_lfc_bdot128.asm"
riscv32-unknown-elf-objcopy \
  -O verilog --verilog-data-width=4 \
  -j .text "${ELF_FILE}" "${BUILD_DIR}/imem.hex"
riscv32-unknown-elf-objcopy \
  -O verilog --verilog-data-width=4 \
  --change-addresses -0x20000000 \
  -j .rodata -j .data \
  "${ELF_FILE}" "${BUILD_DIR}/dmem.hex"

bcfg_sites="$(rg -c '0x2b.*funct3|\.insn' "${BUILD_DIR}/finn_lfc_bdot128.asm" || true)"
custom1_words="$(rg -c '[[:space:]][0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]+' "${BUILD_DIR}/finn_lfc_bdot128.asm" || true)"

if ! rg -q '02b|12b|2b' "${BUILD_DIR}/finn_lfc_bdot128.asm"; then
  echo "ERROR: custom-1 instruction encoding was not found" >&2
  exit 1
fi

echo "LFC BDOT128 built; asm_lines=${custom1_words} bcfg_scan=${bcfg_sites}"

