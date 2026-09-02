#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASE_DIR="$(cd "${PROJECT_DIR}/../260726_XPC32_RegToReg" && pwd)"
SOFTWARE_BUILD="${PROJECT_DIR}/software/lfc/build/bdot128"
GENERATED="${PROJECT_DIR}/software/lfc/generated"
VERILATOR_DIR="/tmp/wide_bdot_lfc_verilator"
LOG_DIR="${SCRIPT_DIR}/logs"

"${PROJECT_DIR}/software/lfc/build_lfc_bdot.sh"
mkdir -p "${LOG_DIR}"

CCACHE_DISABLE=1 verilator --binary --timing -Wno-fatal \
  --top-module rv32i_lfc_bdot_tb \
  --Mdir "${VERILATOR_DIR}" \
  "${BASE_DIR}/src/rtl/basic_modules.v" \
  "${BASE_DIR}/src/rtl/xnor_popcount32.v" \
  "${PROJECT_DIR}/src/rtl/bdot_cpu_control.v" \
  "${PROJECT_DIR}/src/rtl/wide_xnor_popcount.v" \
  "${PROJECT_DIR}/src/rtl/wide_bram_32xwide_model.v" \
  "${PROJECT_DIR}/src/rtl/wide_bdot_accel.v" \
  "${PROJECT_DIR}/src/rtl/rv32i_cpu.v" \
  "${SCRIPT_DIR}/rv32i_lfc_bdot_tb.v"

"${VERILATOR_DIR}/Vrv32i_lfc_bdot_tb" \
  "+IMEM=${SOFTWARE_BUILD}/imem.hex" \
  "+DMEM=${SOFTWARE_BUILD}/dmem.hex" \
  "+WEIGHT=${GENERATED}/weight_128.hex" \
  "+ACT0=${GENERATED}/activation0.hex" \
  "+ACT1=${GENERATED}/activation1.hex" \
  "+GOLDEN0=${GENERATED}/golden_activation0.hex" \
  "+GOLDEN1=${GENERATED}/golden_activation1.hex" \
  "+GOLDEN2=${GENERATED}/golden_activation2.hex" \
  | tee "${LOG_DIR}/rv32i_lfc_bdot.log"
