#!/usr/bin/env bash
#	flow/syn/syn_yosys.sh -- drive the karu64 yosys + opensta flow.
#
#	Outputs land under $KARU_OUT_DIR (timestamped under _build/syn_out/ by
#	default). See README.md for the layout.

set -eu
set -o pipefail

# A supplied manifest uses paths relative to the repository root. Resolve the
# manifest itself before changing to the flow directory.
if [ -n "${KARU_RTL_MANIFEST:-}" ]; then
	case "$KARU_RTL_MANIFEST" in
		/*) ;;
		*) export KARU_RTL_MANIFEST="$PWD/$KARU_RTL_MANIFEST" ;;
	esac
fi
if [ -n "${KARU_SDC_TEMPLATE:-}" ]; then
	case "$KARU_SDC_TEMPLATE" in
		/*) ;;
		*) export KARU_SDC_TEMPLATE="$PWD/$KARU_SDC_TEMPLATE" ;;
	esac
fi
export KARU_TOP="${KARU_TOP:-karu64}"

cd "$(dirname "$0")"

if [ ! -f syn_setup.sh ]; then
	echo "syn_setup.sh missing -- incomplete synthesis flow checkout." >&2
	exit 1
fi
# shellcheck source=/dev/null
. ./syn_setup.sh

if [ "${KARU_DIV_AUDIT_ONLY:-0}" = "1" ]; then
	export KARU_NO_STA=1
fi

if [ ! -f "$KARU_LIB" ]; then
	echo "KARU_LIB does not exist: $KARU_LIB" >&2
	exit 1
fi

mkdir -p "$KARU_OUT_DIR/generated" "$KARU_OUT_DIR/log" "$KARU_OUT_DIR/reports/timing"

input_manifest() {
	# Fingerprint the declared input set and include closure, not unrelated
	# RTL added concurrently for another top. Include tool mapping resources.
	python3 - "$(pwd)/../.." <<'PY'
import hashlib, os, pathlib, re, shlex, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
flow = root / 'flow/syn'
files = {pathlib.Path(os.environ['KARU_LIB']).resolve()}
files.update(flow / name for name in (
    'syn_setup.sh', 'syn_yosys.sh', 'tcl/yosys_run_synth.tcl',
    'tcl/abc_fast.script', 'tcl/sta_run_reports.tcl', 'sdc/karu64.abc.sdc'))
files.add(pathlib.Path(os.environ.get('KARU_SDC_TEMPLATE',
    str(flow / 'sdc/karu64.sdc.in'))).resolve())
sources = []
manifest = os.environ.get('KARU_RTL_MANIFEST')
if manifest:
    path = pathlib.Path(manifest).resolve()
    files.add(path)
    for line in path.read_text().splitlines():
        name = line.split('//', 1)[0].split('#', 1)[0].strip()
        if name:
            source = pathlib.Path(name)
            sources.append(source if source.is_absolute() else root / source)
else:
    excluded = {'karu_clint.v', 'karu_plic.v'}
    sources = [root / 'rtl/karu64.v']
    sources += [p for p in (root / 'rtl').glob('karu_*.v')
                if p.name not in excluded]
    sources += list((root / 'rtl/zvk').glob('*.v'))
defines = dict(token.split('=', 1) for token in
               shlex.split(os.environ.get('KARU_DEFINES', '')) if '=' in token)
pending = [p.resolve() for p in sources]
while pending:
    path = pending.pop()
    if path in files:
        continue
    files.add(path)
    text = re.sub(r'/\*.*?\*/', '', path.read_text(), flags=re.S)
    for match in re.finditer(r'^\s*`include\s+("[^"]+"|`\w+)', text, re.M):
        token = match.group(1)
        if token.startswith('`'):
            value = defines.get(token[1:])
            if value is None:
                continue  # An active undefined include also fails the frontend.
            name = value.strip('\\"')
        else:
            name = token[1:-1]
        candidates = [path.parent / name, flow / name,
                      root / 'rtl' / name, root / 'dbg' / name]
        include = next((p.resolve() for p in candidates if p.is_file()), None)
        if include is None:
            raise SystemExit(f'Cannot fingerprint include {name!r} from {path}')
        pending.append(include)
yosys = pathlib.Path(shutil.which('yosys')).resolve()
config = yosys.parent / 'yosys-config'
data = (pathlib.Path(subprocess.check_output([str(config), '--datdir'], text=True).strip())
        if config.is_file() else yosys.parent.parent / 'share/yosys')
if not data.is_dir():
    raise SystemExit(f'Cannot fingerprint Yosys mapping resources: {data}')
files.update(p.resolve() for p in data.rglob('*')
             if p.is_file() and p.suffix in {'.v', '.vh', '.lib'})
for path in sorted(files):
    print(hashlib.sha256(path.read_bytes()).hexdigest(), ' ', path, sep='')
PY
}
input_manifest > "$KARU_OUT_DIR/log/inputs.before.sha256"

# Bind measurements to the actual working-tree sources, not only a commit ID.
# Git commands here are read-only; builds never alter repository state.
{
	date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
	yosys -V
	yosys_path=$(command -v yosys)
	printf 'YOSYS_EXECUTABLE=%s\n' "$yosys_path"
	sha256sum "$yosys_path"
	yosys_abc_path=$(command -v yosys-abc)
	printf 'YOSYS_ABC_EXECUTABLE=%s\n' "$yosys_abc_path"
	sha256sum "$yosys_abc_path"
	if [ "${KARU_NO_STA:-0}" != "1" ] && [ "${KARU_NO_STA:-}" != "yes" ]; then
		sta -version
		sta_path=$(command -v sta)
		printf 'OPENSTA_EXECUTABLE=%s\n' "$sta_path"
		sha256sum "$sta_path"
	fi
	if command -v git >/dev/null 2>&1 && git -C ../.. rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C ../.. rev-parse HEAD
		git -C ../.. status --short -- rtl flow/syn
	fi
	printf 'KARU_DEFINES=%s\nKARU_CLK_PS=%s\nKARU_ABC_UPRATE_PS=%s\n' "$KARU_DEFINES" "$KARU_CLK_PS" "$KARU_ABC_UPRATE_PS"
	printf 'KARU_TOP=%s\nKARU_RTL_MANIFEST=%s\n' "$KARU_TOP" "${KARU_RTL_MANIFEST:-}"
	printf 'KARU_SDC_TEMPLATE=%s\nKARU_TCK_PS=%s\n' "${KARU_SDC_TEMPLATE:-}" "${KARU_TCK_PS:-100000}"
	printf 'KARU_IN_PCT=%s\nKARU_OUT_PCT=%s\nKARU_NOSHARE=%s\n' "$KARU_IN_PCT" "$KARU_OUT_PCT" "${KARU_NOSHARE:-}"
	printf 'KARU_NO_STA=%s\nKARU_ABC_FULL=%s\nKARU_ABC_FAST=%s\nKARU_FLATTEN=%s\nKARU_DIV_AUDIT_ONLY=%s\n' "${KARU_NO_STA:-}" "${KARU_ABC_FULL:-}" "${KARU_ABC_FAST:-}" "${KARU_FLATTEN:-}" "${KARU_DIV_AUDIT_ONLY:-}"
	cat "$KARU_OUT_DIR/log/inputs.before.sha256"
} > "$KARU_OUT_DIR/log/manifest.txt"

#	Generate the SDC: substitute clock period & IO delay percentages
#	from env into the template.
clk_ns=$(awk "BEGIN{printf \"%.4f\", $KARU_CLK_PS/1000.0}")
in_ns=$(awk  "BEGIN{printf \"%.4f\", ($KARU_IN_PCT/100.0)*($KARU_CLK_PS/1000.0)}")
out_ns=$(awk "BEGIN{printf \"%.4f\", (1.0 - $KARU_OUT_PCT/100.0)*($KARU_CLK_PS/1000.0)}")
tck_ns=$(awk "BEGIN{printf \"%.4f\", ${KARU_TCK_PS:-100000}/1000.0}")

sed -e "s/@CLK_NS@/$clk_ns/g" \
    -e "s/@IN_NS@/$in_ns/g"  \
    -e "s/@OUT_NS@/$out_ns/g" \
    -e "s/@TCK_NS@/$tck_ns/g" \
	"${KARU_SDC_TEMPLATE:-sdc/karu64.sdc.in}" > "$KARU_OUT_DIR/generated/$KARU_TOP.sdc"

#	ABC SDC is the same minus the clock (yosys' abc pass takes the
#	period via -D and only wants the driving cell / load).
cp sdc/karu64.abc.sdc "$KARU_OUT_DIR/generated/$KARU_TOP.abc.sdc"

export KARU_OUT_DIR KARU_LIB KARU_CLK_PS KARU_ABC_UPRATE_PS

echo "===== yosys synthesis ====="
yosys -c tcl/yosys_run_synth.tcl 2>&1 | tee "$KARU_OUT_DIR/log/syn.log"

if [ "${KARU_DIV_AUDIT_ONLY:-0}" = "1" ]; then
	input_manifest > "$KARU_OUT_DIR/log/inputs.after.sha256"
	cmp -s "$KARU_OUT_DIR/log/inputs.before.sha256" "$KARU_OUT_DIR/log/inputs.after.sha256" || {
		echo "synthesis inputs changed during the structural audit" >&2
		diff -u "$KARU_OUT_DIR/log/inputs.before.sha256" "$KARU_OUT_DIR/log/inputs.after.sha256" >&2 || true
		exit 1
	}
	exit 0
fi

if [ "${KARU_NO_STA:-0}" = "1" ] || [ "${KARU_NO_STA:-}" = "yes" ]; then
	echo "===== opensta skipped (KARU_NO_STA) ====="
else
	echo "===== opensta reports ====="
	sta -no_init -no_splash tcl/sta_run_reports.tcl 2>&1 | tee "$KARU_OUT_DIR/log/sta.log"
	# OpenSTA may report a Tcl/SDC error without a failing process status.
	if grep -Eq '^Error:|^error:' "$KARU_OUT_DIR/log/sta.log"; then
		echo "OpenSTA reported an error; timing results are invalid" >&2
		exit 1
	fi
fi

input_manifest > "$KARU_OUT_DIR/log/inputs.after.sha256"
cmp -s "$KARU_OUT_DIR/log/inputs.before.sha256" "$KARU_OUT_DIR/log/inputs.after.sha256" || {
	echo "synthesis inputs changed while the flow was running" >&2
	diff -u "$KARU_OUT_DIR/log/inputs.before.sha256" "$KARU_OUT_DIR/log/inputs.after.sha256" >&2 || true
	exit 1
}

echo
echo "===== summary ====="
echo "outputs in $KARU_OUT_DIR/"
grep -E "^\s+(Chip area|Number of cells|Number of wires)" \
	"$KARU_OUT_DIR/reports/area.rpt" 2>/dev/null || true
echo "WNS (reg2reg): $(awk -F, 'BEGIN{m=1e9} {if($3+0<m)m=$3+0} END{printf "%.4f ns\n", m}' \
	"$KARU_OUT_DIR/reports/timing/reg2reg.csv.rpt" 2>/dev/null || echo 'n/a')"
