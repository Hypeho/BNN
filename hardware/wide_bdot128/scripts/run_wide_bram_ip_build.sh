#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/vivado/build/wide_bram_ip"
LOG_DIR="${PROJECT_DIR}/vivado/logs"

mkdir -p "${BUILD_DIR}" "${LOG_DIR}"

vivado -mode batch -nojournal -nolog \
  -source "${SCRIPT_DIR}/create_wide_bram_ips.tcl" \
  -tclargs "${BUILD_DIR}" \
  2>&1 | tee "${LOG_DIR}/wide_bram_ip_build.log"

if ! rg -q "BMG IP BUILD PASS" "${LOG_DIR}/wide_bram_ip_build.log"; then
  echo "ERROR: Vivado did not report BMG IP BUILD PASS" >&2
  exit 1
fi
