#!/usr/bin/env bash
# Build the openTPU bitstream for the AMD ZCU104 in Vivado batch mode (`vivado` on PATH, 2025.2;
# the XCZU7EV is in Vivado's no-cost edition).
#
#   ./run_vivado.sh               # project, synthesis, implementation, bitstream
#   STEP=impl ./run_vivado.sh     # rerun implementation only (keeps project and synthesis)
#   FAST=1 ./run_vivado.sh        # development build: default strategies, no retiming or post-route phys_opt
#   OUT_DIR=... JOBS=... BUILD_ID=...
#
# The accelerator's parameters are the target's (targets/zcu104.toml): the YPCB-00338's [arch].
# Output: build/zcu104/otpu.bit, otpu.bin, otpu_zcu104.xsa, reports/ (SUMMARY.txt first).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${OUT_DIR:-$root/build/zcu104}"
jobs="${JOBS:-8}"
step="${STEP:-full}"
export OTPU_FAST="${FAST:-0}"
export OTPU_IP_CACHE="${OTPU_IP_CACHE:-$root/build/ip_cache}"
mkdir -p "$out"
if [ "$step" != "impl" ]; then
  vivado -mode batch -nojournal -log "$out/create_project.log" \
    -source "$here/vivado/create_project.tcl" -tclargs "$out" "${BUILD_ID:-}"
fi
vivado -mode batch -nojournal -log "$out/build.log" \
  -source "$here/vivado/build.tcl" -tclargs "$out" "$jobs" "$step"
cat "$out/reports/SUMMARY.txt"
