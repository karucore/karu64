#!/usr/bin/env bash
#	with_vivado.sh -- run a command inside the Vivado environment.
#
#	Vivado's settings prepend its own bin/ (incl. a bundled verilator) to PATH,
#	which would shadow the sim toolchain (~/.local/bin/verilator, iverilog,
#	spike). Sourcing it here in an isolated subshell keeps that contamination
#	contained to the wrapped command -- the parent shell stays clean, so the
#	Makefile's verilator/iverilog/spike targets keep working in the same session.
#
#	Usage:
#	    flow/with_vivado.sh make elab-ddr
#	    flow/with_vivado.sh make vcu118-ddr
#	    flow/with_vivado.sh vivado -version
set -euo pipefail
if [ -z "${VIVADO_SETTINGS:-}" ]; then
	for candidate in \
		"$HOME/Xilinx/2026.1/Vivado/settings64.sh" \
		"$HOME/Xilinx/2025.2.1/Vivado/.settings64-Vivado.sh"; do
		if [ -r "$candidate" ]; then
			VIVADO_SETTINGS="$candidate"
			break
		fi
	done
fi
VIVADO_SETTINGS="${VIVADO_SETTINGS:-$HOME/Xilinx/2026.1/Vivado/settings64.sh}"
if [ ! -r "$VIVADO_SETTINGS" ]; then
	echo "with_vivado.sh: ERROR: cannot read $VIVADO_SETTINGS" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "$VIVADO_SETTINGS"
exec "$@"
