#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RV32I_PROJECT="$(cd "${ROOT_DIR}/../../.." && pwd)"
FINN_DIR="${RV32I_PROJECT}/TinyML/BNN/finn"
EBNN_DATA="${RV32I_PROJECT}/TinyML/BNN/ebnn/examples/binary_mnist_data.h"
PYTHON_BIN="${FINN_ANALYSIS_PYTHON:-/tmp/finn_rv32i_venv/bin/python}"
BUILD_DIR="${ROOT_DIR}/build"
PARAM_DIR="${ROOT_DIR}/generated"

mkdir -p "${BUILD_DIR}" "${PARAM_DIR}"

if [[ "${REGENERATE_PARAMS:-0}" == "1" || ! -f "${PARAM_DIR}/lfc_params.h" ]]; then
  "${PYTHON_BIN}" "${ROOT_DIR}/analysis/generate_lfc_params.py" \
    --onnx "${FINN_DIR}/notebooks/LFCW1A1.onnx" \
    --ebnn-data "${EBNN_DATA}" \
    --output "${PARAM_DIR}/lfc_params.h"
fi

riscv32-unknown-elf-gcc \
  -march=rv32i -mabi=ilp32 -O2 -g0 \
  -ffunction-sections -fdata-sections -fno-builtin -nostdlib \
  -I"${PARAM_DIR}" -Wl,--gc-sections -Wl,-Map,"${BUILD_DIR}/finn_lfc.map" \
  -T "${ROOT_DIR}/RISC-V/memory.ld" \
  "${ROOT_DIR}/RISC-V/crt0.S" "${ROOT_DIR}/RISC-V/main_finn_lfc_rv32i.c" \
  -lgcc -o "${BUILD_DIR}/finn_lfc.elf"

riscv32-unknown-elf-size "${BUILD_DIR}/finn_lfc.elf"
riscv32-unknown-elf-objdump -d -S "${BUILD_DIR}/finn_lfc.elf" > "${BUILD_DIR}/finn_lfc.asm"
riscv32-unknown-elf-objcopy -O verilog --verilog-data-width=4 \
  -j .text "${BUILD_DIR}/finn_lfc.elf" "${BUILD_DIR}/imem.hex"
riscv32-unknown-elf-objcopy -O verilog --verilog-data-width=4 \
  --change-addresses -0x20000000 -j .rodata -j .data \
  "${BUILD_DIR}/finn_lfc.elf" "${BUILD_DIR}/dmem.hex"

riscv32-unknown-elf-objdump -h "${BUILD_DIR}/finn_lfc.elf"
