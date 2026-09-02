#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build_pc"

mkdir -p "${BUILD_DIR}"

EXTRA_CFLAGS=()
if [[ -n "${EBNN_RUN_SAMPLES:-}" ]]; then
  EXTRA_CFLAGS+=("-DEBNN_RUN_SAMPLES=${EBNN_RUN_SAMPLES}")
fi

gcc -O2 \
  "${EXTRA_CFLAGS[@]}" \
  -I"${ROOT_DIR}/common" \
  "${ROOT_DIR}/PC/ebnn_binary_mnist_host_ref.c" \
  -o "${BUILD_DIR}/ebnn_binary_mnist_host_ref"

"${BUILD_DIR}/ebnn_binary_mnist_host_ref"
