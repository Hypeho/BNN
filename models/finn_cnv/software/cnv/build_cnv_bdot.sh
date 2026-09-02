#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_CNV_DIR="$(cd "${PROJECT_DIR}/../260719_FINN_CNV_RV32I" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build/bdot128"
ELF_FILE="${BUILD_DIR}/finn_cnv_bdot128.elf"

python3 "${SCRIPT_DIR}/generate_cnv_bdot_images.py"
mkdir -p "${BUILD_DIR}"

riscv32-unknown-elf-gcc \
  -march=rv32i -mabi=ilp32 -O2 -g0 \
  -ffunction-sections -fdata-sections -fno-builtin -nostdlib \
  -I"${SCRIPT_DIR}" -Wl,--gc-sections \
  -Wl,-Map,"${BUILD_DIR}/finn_cnv_bdot128.map" \
  -T "${SCRIPT_DIR}/memory_bdot.ld" \
  "${SOURCE_CNV_DIR}/RISC-V/crt0.S" \
  "${SCRIPT_DIR}/main_finn_cnv_bdot.c" \
  -lgcc -o "${ELF_FILE}"

riscv32-unknown-elf-size "${ELF_FILE}"
riscv32-unknown-elf-objdump -d -S "${ELF_FILE}" > "${BUILD_DIR}/finn_cnv_bdot128.asm"
riscv32-unknown-elf-objcopy -O verilog --verilog-data-width=4 \
  -j .text "${ELF_FILE}" "${BUILD_DIR}/imem.hex"
riscv32-unknown-elf-objcopy -O verilog --verilog-data-width=4 \
  --change-addresses -0x20000000 -j .rodata -j .data \
  "${ELF_FILE}" "${BUILD_DIR}/dmem.hex"

if ! rg -q '02b|12b|2b' "${BUILD_DIR}/finn_cnv_bdot128.asm"; then
  echo "ERROR: custom-1 instruction encoding was not found" >&2
  exit 1
fi
echo "FINN CNV BDOT128 software built"
