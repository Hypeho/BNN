#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/vivado/build/wide_bdot_core"
LOG_DIR="${PROJECT_DIR}/vivado/logs"

mkdir -p "${BUILD_DIR}" "${LOG_DIR}"
vivado -mode batch -nojournal -nolog \
  -source "${SCRIPT_DIR}/run_wide_bdot_core_synth.tcl" \
  -tclargs "${BUILD_DIR}" \
  2>&1 | tee "${LOG_DIR}/wide_bdot_core_synth.log"

if ! rg -q "WIDE BDOT CORE SYNTH PASS" "${LOG_DIR}/wide_bdot_core_synth.log"; then
  echo "ERROR: Vivado did not report WIDE BDOT CORE SYNTH PASS" >&2
  exit 1
fi

