#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="$(cd "${PROJECT_DIR}/../260726_XPC32_RegToReg" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build/verilator_cnv_bdot"
SOFTWARE_DIR="${PROJECT_DIR}/software/cnv"

"${SOFTWARE_DIR}/build_cnv_bdot.sh"
mkdir -p "${BUILD_DIR}"

CCACHE_DISABLE=1 verilator --binary --timing -Wno-fatal \
  --top-module rv32i_cnv_bdot_tb --Mdir "${BUILD_DIR}" \
  "${BASE_DIR}/src/rtl/basic_modules.v" \
  "${BASE_DIR}/src/rtl/xnor_popcount32.v" \
  "${PROJECT_DIR}/src/rtl/bdot_cpu_control.v" \
  "${PROJECT_DIR}/src/rtl/wide_xnor_popcount.v" \
  "${PROJECT_DIR}/src/rtl/wide_bram_32xwide_model.v" \
  "${PROJECT_DIR}/src/rtl/wide_bdot_accel.v" \
  "${PROJECT_DIR}/src/rtl/rv32i_cpu.v" \
  "${PROJECT_DIR}/testbench/rv32i_cnv_bdot_tb.v"

"${BUILD_DIR}/Vrv32i_cnv_bdot_tb" \
  +IMEM="${SOFTWARE_DIR}/build/bdot128/imem.hex" \
  +DMEM="${SOFTWARE_DIR}/build/bdot128/dmem.hex" \
  +WEIGHT="${SOFTWARE_DIR}/generated/weight_128.hex" \
  +ACT0="${SOFTWARE_DIR}/generated/activation0.hex" \
  +ACT1="${SOFTWARE_DIR}/generated/activation1.hex"
