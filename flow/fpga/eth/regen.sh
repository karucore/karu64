#!/usr/bin/env bash
#	regen.sh — regenerate the vendored LiteEth standalone core (Phase E0).
#
#	Reproducibly regenerates liteeth_core.v + the CSR map from liteeth_sim.yml
#	using pinned migen/litex/liteeth commits. Idempotent: if $LITEX_DIR has the
#	venv already, it is reused; otherwise the toolchain is cloned + installed.
#
#	Usage:   ./regen.sh
#	Env:     LITEX_DIR (default ~/litex)   — where the LiteX toolchain lives.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LITEX_DIR="${LITEX_DIR:-$HOME/litex}"

#	Optional args (default = the legacy MII loopback core, byte-identical to before):
#	  $1 = yml config       (default $HERE/liteeth_sim.yml)
#	  $2 = output basename  (default empty => liteeth_core.v + liteeth_csr.{csv,json})
#	With $2 set, outputs $2.v + ${2}_csr.{csv,json} + $2.{xdc,tcl} instead, so a second
#	config (e.g. liteeth_gmii.yml -> liteeth_core_gmii) does NOT clobber the loopback
#	core. The generated module is named `liteeth_core` either way, so any one build must
#	read exactly one of the cores.
YML_CFG="${1:-$HERE/liteeth_sim.yml}"
OUTBASE="${2:-}"
PART="${LITEETH_VIVADO_PART:-xcvu9p-flga2104-2L-e}"

#	Pinned upstream commits (recorded 2026-06-04, the E0 bring-up versions).
MIGEN_REF=e19524c
LITEX_REF=61bce27
LITEETH_REF=456c059

clone_at() {	#	repo url, dir, ref
	local url="$1" dir="$2" ref="$3"
	if [ ! -d "$LITEX_DIR/$dir" ]; then
		git clone "$url" "$LITEX_DIR/$dir"
	fi
	git -C "$LITEX_DIR/$dir" fetch --depth 50 origin || true
	git -C "$LITEX_DIR/$dir" checkout "$ref" 2>/dev/null || \
		echo "WARN: could not checkout $dir@$ref (using current HEAD)"
}

fix_vivado_tcl() {	#	tcl path, output basename
	local tcl="$1" base="$2"
	perl -0pi \
		-e 's/# Create Project\n/# Create Project\n\nsource [file join [file dirname [file normalize [info script]]] .. vivado_paths.tcl]\ncd $::karu_build_dir\n\n/' \
		-e "s|create_project -force -name liteeth_core -part[^\\n]*|create_project -force -name ${base} -part $PART|" \
		-e "s|read_verilog \\{[^\\n]*liteeth_core\\.v\\}|read_verilog [file join [file dirname [file normalize [info script]]] ${base}.v]|" \
		-e "s|read_xdc liteeth_core\\.xdc|read_xdc [file join [file dirname [file normalize [info script]]] ${base}.xdc]|" \
		-e "s|get_files liteeth_core\\.xdc|get_files [file join [file dirname [file normalize [info script]]] ${base}.xdc]|" \
		-e "s|-file liteeth_core([A-Za-z0-9_.-]*)|-file [karu_build_path ${base}\$1]|g" \
		-e "s|write_checkpoint -force liteeth_core([A-Za-z0-9_.-]*)|write_checkpoint -force [karu_build_path ${base}\$1]|g" \
		-e "s|write_bitstream -force liteeth_core\\.bit\\s*|write_bitstream -force [karu_build_path ${base}.bit]|g" \
		"$tcl"
}

if [ ! -x "$LITEX_DIR/venv/bin/python" ]; then
	echo "== bootstrapping LiteX toolchain into $LITEX_DIR =="
	mkdir -p "$LITEX_DIR"
	python3 -m venv "$LITEX_DIR/venv"
	"$LITEX_DIR/venv/bin/pip" install --upgrade pip setuptools wheel
	clone_at https://github.com/m-labs/migen          migen   "$MIGEN_REF"
	clone_at https://github.com/enjoy-digital/litex    litex   "$LITEX_REF"
	clone_at https://github.com/enjoy-digital/liteeth  liteeth "$LITEETH_REF"
	"$LITEX_DIR/venv/bin/pip" install -e "$LITEX_DIR/migen" \
		-e "$LITEX_DIR/litex" -e "$LITEX_DIR/liteeth"
fi

PY="$LITEX_DIR/venv/bin/python"
GEN="$LITEX_DIR/liteeth/liteeth/gen.py"

echo "== migen   $(git -C "$LITEX_DIR/migen"   rev-parse --short HEAD 2>/dev/null)"
echo "== litex   $(git -C "$LITEX_DIR/litex"   rev-parse --short HEAD 2>/dev/null)"
echo "== liteeth $(git -C "$LITEX_DIR/liteeth" rev-parse --short HEAD 2>/dev/null)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "== gen config: $YML_CFG${OUTBASE:+  (output basename: $OUTBASE)}"
"$PY" "$GEN" \
	--output-dir="$TMP" --gateware-dir="$TMP" --no-compile \
	--csr-csv="$TMP/csr.csv" --csr-json="$TMP/csr.json" \
	"$YML_CFG"

if [ -n "$OUTBASE" ]; then
	cp "$TMP/liteeth_core.v"   "$HERE/$OUTBASE.v"
	python3 "$HERE/../../flow/eth_mdio_guard.py" "$HERE/$OUTBASE.v"
	cp "$TMP/csr.csv"          "$HERE/${OUTBASE}_csr.csv"
	cp "$TMP/csr.json"         "$HERE/${OUTBASE}_csr.json"
	cp "$TMP/liteeth_core.xdc" "$HERE/$OUTBASE.xdc"
	cp "$TMP/liteeth_core.tcl" "$HERE/$OUTBASE.tcl"
	fix_vivado_tcl "$HERE/$OUTBASE.tcl" "$OUTBASE"
	echo "== regenerated $OUTBASE into $HERE =="
	grep -E '^csr_base|^memory_region' "$HERE/${OUTBASE}_csr.csv"
else
	cp "$TMP/liteeth_core.v"   "$HERE/liteeth_core.v"
	python3 "$HERE/../../flow/eth_mdio_guard.py" "$HERE/liteeth_core.v"
	cp "$TMP/csr.csv"          "$HERE/liteeth_csr.csv"
	cp "$TMP/csr.json"         "$HERE/liteeth_csr.json"
	cp "$TMP/liteeth_core.xdc" "$HERE/liteeth_core.xdc"
	cp "$TMP/liteeth_core.tcl" "$HERE/liteeth_core.tcl"
	fix_vivado_tcl "$HERE/liteeth_core.tcl" "liteeth_core"
	echo "== regenerated into $HERE =="
	grep -E '^csr_base|^memory_region' "$HERE/liteeth_csr.csv"
fi
