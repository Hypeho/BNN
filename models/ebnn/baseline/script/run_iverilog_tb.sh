#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../../.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build_rv32i"
SIM_EXE="${BUILD_DIR}/ebnn_binary_mnist_tb.vvp"
SIM_LOG="${BUILD_DIR}/ebnn_binary_mnist_tb.log"

EBNN_RUN_SAMPLES="${EBNN_RUN_SAMPLES:-1}" "${SCRIPT_DIR}/build_ebnn_rv32i.sh"

iverilog -g2012 \
  -o "${SIM_EXE}" \
  "${REPO_DIR}/Single_cycle/src/rtl/RV32I_System.v" \
  "${REPO_DIR}/Single_cycle/src/rtl/rv32i_cpu.v" \
  "${REPO_DIR}/Single_cycle/src/rtl/basic_modules.v" \
  "${REPO_DIR}/Single_cycle/src/rtl/inst_memory.v" \
  "${REPO_DIR}/Single_cycle/src/rtl/data_memory.v" \
  "${ROOT_DIR}/testbench/RV32I_System_ebnn_tb.v"

(
  cd "${BUILD_DIR}"
  vvp "${SIM_EXE}"
) | tee "${SIM_LOG}"

echo "Simulation log: ${SIM_LOG}"
