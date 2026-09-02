#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RV32I_PROJECT="$(cd "${ROOT_DIR}/../../.." && pwd)"
TORCH_PYTHON="${TORCH_PYTHON:-${RV32I_PROJECT}/FPGA/BNN/260609_BNN_LeNet/.venv/bin/python}"
BREVITAS_SRC="${BREVITAS_SRC:-/tmp/finn_brevitas_src/src}"
BREVITAS_DEPS="${BREVITAS_DEPS:-/tmp/finn_brevitas_deps}"
CHECKPOINT="${CNV_CHECKPOINT:-/tmp/cnv_1w1a-758c8fef.pth}"
SAMPLE="${RV32I_PROJECT}/TinyML/BNN/finn/src/finn/qnn-data/cifar10/cifar10-test-data-class3.npz"
BUILD_DIR="${ROOT_DIR}/build"
PARAM_DIR="${ROOT_DIR}/generated"
mkdir -p "${BUILD_DIR}" "${PARAM_DIR}"

if [[ "${REGENERATE_PARAMS:-0}" == "1" || ! -f "${PARAM_DIR}/cnv_params.h" ]]; then
  PYTHONPATH="${BREVITAS_DEPS}:/usr/lib/python3/dist-packages:${BREVITAS_SRC}" \
    "${TORCH_PYTHON}" "${ROOT_DIR}/analysis/generate_cnv_params.py" \
    --checkpoint "${CHECKPOINT}" --sample "${SAMPLE}" \
    --output "${PARAM_DIR}/cnv_params.h"
fi

cc -O3 -DFINN_HOST -I"${PARAM_DIR}" \
  "${ROOT_DIR}/RISC-V/main_finn_cnv_rv32i.c" -o "${BUILD_DIR}/finn_cnv_host"
"${BUILD_DIR}/finn_cnv_host"

riscv32-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 -g0 \
  -ffunction-sections -fdata-sections -fno-builtin -nostdlib \
  -I"${PARAM_DIR}" -Wl,--gc-sections -Wl,-Map,"${BUILD_DIR}/finn_cnv.map" \
  -T "${ROOT_DIR}/RISC-V/memory.ld" \
  "${ROOT_DIR}/RISC-V/crt0.S" "${ROOT_DIR}/RISC-V/main_finn_cnv_rv32i.c" \
  -lgcc -o "${BUILD_DIR}/finn_cnv.elf"
riscv32-unknown-elf-size "${BUILD_DIR}/finn_cnv.elf"
riscv32-unknown-elf-objdump -d -S "${BUILD_DIR}/finn_cnv.elf" > "${BUILD_DIR}/finn_cnv.asm"
riscv32-unknown-elf-objcopy -O verilog --verilog-data-width=4 -j .text \
  "${BUILD_DIR}/finn_cnv.elf" "${BUILD_DIR}/imem.hex"
riscv32-unknown-elf-objcopy -O verilog --verilog-data-width=4 --change-addresses -0x20000000 \
  -j .rodata -j .data "${BUILD_DIR}/finn_cnv.elf" "${BUILD_DIR}/dmem.hex"
riscv32-unknown-elf-objdump -h "${BUILD_DIR}/finn_cnv.elf"
