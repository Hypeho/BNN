#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/vivado/build/wide_bram_bmg_sim"
LOG_DIR="${PROJECT_DIR}/vivado/logs"

mkdir -p "${BUILD_DIR}" "${LOG_DIR}"
vivado -mode batch -nojournal -nolog \
  -source "${SCRIPT_DIR}/run_wide_bram_bmg_sim.tcl" \
  -tclargs "${BUILD_DIR}" \
  2>&1 | tee "${LOG_DIR}/wide_bram_bmg_sim.log"

if ! rg -q "TB PASS: wide_bram_bmg_equivalence" "${LOG_DIR}/wide_bram_bmg_sim.log"; then
  echo "ERROR: BMG equivalence test did not pass" >&2
  exit 1
fi

