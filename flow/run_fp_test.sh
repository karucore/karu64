#!/usr/bin/env bash
#	flow/run_fp_test.sh -- run one Berkeley TestFloat operation through
#	karu64 (verilator), then pipe the result lines to testfloat_ver.
#
#	Usage:	flow/run_fp_test.sh <tf_op> [chunk_size]
#	  env:  RM=<rne|rtz|rdn|rup|rmm|dyn>  FRM=<rne|rtz|rdn|rup|rmm>
#	        PARALLEL=<N>  (chunks in flight; default 20)
#	        WORK_KEEP=<dir>  (keep work dir for inspection)
#
#	Vector layout in RAM (set by the orchestrator, consumed by
#	test/fw/fp_subj.c):
#	  in[0]=op_id, in[1]=n_vec, in[2]=frm, in[3]=input_stride_u32
#	  in[4..] = records, stride = input_stride_u32 u32s per record
#	Output blob: 4 u32 per record = [r_lo, r_hi, flags, _]
#	The script paste-joins the per-record (result, flags) text back
#	with the original operand line(s) from testfloat_gen.

set -u
cd "$(dirname "$0")/.."

TF_OP=${1:?"usage: $0 <tf_op> [chunk_size]"}
CHUNK=${2:-16384}

RM=${RM:-rne}
FRM=${FRM:-rne}
case $RM in rne|rtz|rdn|rup|rmm|dyn) ;; *) echo "bad RM=$RM"; exit 2 ;; esac
case $FRM in rne|rtz|rdn|rup|rmm)    ;; *) echo "bad FRM=$FRM"; exit 2 ;; esac

to_tf_flag() {
	case $1 in
		rne) echo "-rnear_even"     ;;
		rtz) echo "-rminMag"        ;;
		rdn) echo "-rmin"           ;;
		rup) echo "-rmax"           ;;
		rmm) echo "-rnear_maxMag"   ;;
	esac
}
to_frm_val() {
	case $1 in
		rne) echo 0 ;;
		rtz) echo 1 ;;
		rdn) echo 2 ;;
		rup) echo 3 ;;
		rmm) echo 4 ;;
	esac
}

if [[ $RM == dyn ]]; then EFF_RM=$FRM; else EFF_RM=$RM; fi
RM_FLAG=$(to_tf_flag "$EFF_RM")
FRM_VAL=$(to_frm_val "$FRM")

FP_TB=_build/Vhtif_fp/Vhtif_tb
FW_HEX=_build/fp_subj_${RM}.hex
TF_DIR=_build/TestFloat-3e
TF_GEN=$TF_DIR/testfloat_gen
TF_VER=$TF_DIR/testfloat_ver

if [[ -n ${WORK_KEEP:-} ]]; then
	WORK=$WORK_KEEP; mkdir -p "$WORK"
else
	WORK=$(mktemp -d /tmp/karu_fp_${TF_OP}.XXXXXX)
	trap 'rm -rf "$WORK"' EXIT
fi

#	==========================================================================
#	Per-op table. Columns:
#	  OPID		matches test/fw/fp_subj.c
#	  GEN_ARGS	testfloat_gen <type-args> -- operand-only output
#	  STRIDE	input stride in u32s (4 for f32 ops, 8 for f64 ops)
#	  INFMT		how the awk packs ASCII operand lines into RAM-hex
#	  OUTFMT	how the awk formats per-record (result, flags) for paste
#	==========================================================================
case "$TF_OP" in
	#	---- F (single-precision) ----
	f32_add)	OPID=1;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_f32  ;;
	f32_sub)	OPID=2;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_f32  ;;
	f32_mul)	OPID=3;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_f32  ;;
	f32_div)	OPID=4;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_f32  ;;
	f32_sqrt)	OPID=5;  GEN_ARGS="f32 1"; STRIDE=4; INFMT=un32;  OUTFMT=r_f32  ;;
	f32_mulAdd)	OPID=6;  GEN_ARGS="f32 3"; STRIDE=4; INFMT=ter32; OUTFMT=r_f32  ;;
	f32_eq)		OPID=7;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_bool ;;
	f32_le)		OPID=8;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_bool ;;
	f32_lt)		OPID=9;  GEN_ARGS="f32 2"; STRIDE=4; INFMT=bin32; OUTFMT=r_bool ;;
	f32_to_i32)	OPID=10; GEN_ARGS="f32 1"; STRIDE=4; INFMT=un32;  OUTFMT=r_f32  ;;
	f32_to_ui32)	OPID=11; GEN_ARGS="f32 1"; STRIDE=4; INFMT=un32;  OUTFMT=r_f32  ;;
	f32_to_i64)	OPID=12; GEN_ARGS="f32 1"; STRIDE=4; INFMT=un32;  OUTFMT=r_i64  ;;
	f32_to_ui64)	OPID=13; GEN_ARGS="f32 1"; STRIDE=4; INFMT=un32;  OUTFMT=r_i64  ;;
	i32_to_f32)	OPID=14; GEN_ARGS="i32";   STRIDE=4; INFMT=un32;  OUTFMT=r_f32  ;;
	ui32_to_f32)	OPID=15; GEN_ARGS="ui32";  STRIDE=4; INFMT=un32;  OUTFMT=r_f32  ;;
	i64_to_f32)	OPID=16; GEN_ARGS="i64";   STRIDE=4; INFMT=in_u64; OUTFMT=r_f32 ;;
	ui64_to_f32)	OPID=17; GEN_ARGS="ui64";  STRIDE=4; INFMT=in_u64; OUTFMT=r_f32 ;;

	#	---- D (double-precision) ----
	f64_add)	OPID=20; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_f64  ;;
	f64_sub)	OPID=21; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_f64  ;;
	f64_mul)	OPID=22; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_f64  ;;
	f64_div)	OPID=23; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_f64  ;;
	f64_sqrt)	OPID=24; GEN_ARGS="f64 1"; STRIDE=8; INFMT=un64;  OUTFMT=r_f64  ;;
	f64_mulAdd)	OPID=25; GEN_ARGS="f64 3"; STRIDE=8; INFMT=ter64; OUTFMT=r_f64  ;;
	f64_eq)		OPID=26; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_bool ;;
	f64_le)		OPID=27; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_bool ;;
	f64_lt)		OPID=28; GEN_ARGS="f64 2"; STRIDE=8; INFMT=bin64; OUTFMT=r_bool ;;
	f64_to_i32)	OPID=29; GEN_ARGS="f64 1"; STRIDE=8; INFMT=un64;  OUTFMT=r_f32  ;;
	f64_to_ui32)	OPID=30; GEN_ARGS="f64 1"; STRIDE=8; INFMT=un64;  OUTFMT=r_f32  ;;
	f64_to_i64)	OPID=31; GEN_ARGS="f64 1"; STRIDE=8; INFMT=un64;  OUTFMT=r_i64  ;;
	f64_to_ui64)	OPID=32; GEN_ARGS="f64 1"; STRIDE=8; INFMT=un64;  OUTFMT=r_i64  ;;
	i32_to_f64)	OPID=33; GEN_ARGS="i32";   STRIDE=8; INFMT=in_w; OUTFMT=r_f64  ;;
	ui32_to_f64)	OPID=34; GEN_ARGS="ui32";  STRIDE=8; INFMT=in_w; OUTFMT=r_f64  ;;
	i64_to_f64)	OPID=35; GEN_ARGS="i64";   STRIDE=8; INFMT=in_l; OUTFMT=r_f64  ;;
	ui64_to_f64)	OPID=36; GEN_ARGS="ui64";  STRIDE=8; INFMT=in_l; OUTFMT=r_f64  ;;
	f32_to_f64)	OPID=37; GEN_ARGS="f32 1"; STRIDE=8; INFMT=in_w; OUTFMT=r_f64  ;;
	f64_to_f32)	OPID=38; GEN_ARGS="f64 1"; STRIDE=8; INFMT=un64; OUTFMT=r_f32  ;;
	*) echo "unknown TF_OP: $TF_OP"; exit 2 ;;
esac

#	RV always raises NX on inexact float->int conversion (per spec).
#	testfloat_ver defaults to -notexact, so pass -exact for those ops.
case "$TF_OP" in
	f32_to_*|f64_to_i*|f64_to_u*)	VER_OPTS="-exact" ;;
	*)								VER_OPTS=""        ;;
esac

[[ -x $TF_GEN  ]] || { echo "missing $TF_GEN (run: make testfloat-build)"; exit 2; }
[[ -x $TF_VER  ]] || { echo "missing $TF_VER (run: make testfloat-build)"; exit 2; }
[[ -e $FW_HEX  ]] || { echo "missing $FW_HEX (run: make $FW_HEX)";          exit 2; }
[[ -e $FP_TB   ]] || { echo "missing $FP_TB (run: make $FP_TB)";            exit 2; }

#	==========================================================================
#	1. Generate operand stream from testfloat_gen
#	==========================================================================
$TF_GEN $RM_FLAG -level 1 $GEN_ARGS 2>/dev/null > "$WORK/operands.txt"
NTOTAL=$(wc -l < "$WORK/operands.txt")
NCHUNKS=$(( (NTOTAL + CHUNK - 1) / CHUNK ))
echo "[fp-test] op=$TF_OP RM=$RM FRM=$FRM (eff=$EFF_RM)  gen=$NTOTAL vectors; chunk=$CHUNK ($NCHUNKS chunks)"

OUT_WORD_START=131072	# byte 0x100000 / 8 -> word index 0x20000
PARALLEL=${PARALLEL:-20}
mkdir -p "$WORK/chunks"

run_one_chunk() {
	local ci=$1
	local cd="$WORK/chunks/$ci"
	mkdir -p "$cd"

	sed -n "$((ci * CHUNK + 1)),$(((ci + 1) * CHUNK))p" "$WORK/operands.txt" \
		> "$cd/in.txt"
	local n=$(wc -l < "$cd/in.txt")

	#	ASCII operands -> RAM-hex
	gawk -v OPID="$OPID" -v N="$n" -v FMT="$INFMT" -v FRM="$FRM_VAL" \
		 -v STRIDE="$STRIDE" '
		BEGIN {
			printf "@2000\n"
			printf "%08x%08x\n", N, OPID
			printf "%08x%08x\n", STRIDE, FRM
		}
		#	stride 4: emit 2 ram-words per record
		function emit4(a, b, c) {
			printf "%08x%08x\n", b, a
			printf "%08x%08x\n", 0, c
		}
		#	stride 8: emit 4 ram-words per record
		function emit8(a_lo, a_hi, b_lo, b_hi, c_lo, c_hi) {
			printf "%08x%08x\n", a_hi, a_lo
			printf "%08x%08x\n", b_hi, b_lo
			printf "%08x%08x\n", c_hi, c_lo
			printf "%08x%08x\n", 0, 0
		}
		function pad16(h)   { while (length(h) < 16) h = "0" h; return h }
		function lo32(h)    { return strtonum("0x" substr(pad16(h), 9, 8)) }
		function hi32(h)    { return strtonum("0x" substr(pad16(h), 1, 8)) }
		{
			if (FMT == "bin32") {
				emit4(strtonum("0x"$1), strtonum("0x"$2), 0)
			} else if (FMT == "un32") {
				emit4(strtonum("0x"$1), 0, 0)
			} else if (FMT == "ter32") {
				emit4(strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3))
			} else if (FMT == "in_u64") {
				emit4(lo32($1), hi32($1), 0)
			} else if (FMT == "bin64") {
				emit8(lo32($1), hi32($1), lo32($2), hi32($2), 0, 0)
			} else if (FMT == "un64") {
				emit8(lo32($1), hi32($1), 0, 0, 0, 0)
			} else if (FMT == "ter64") {
				emit8(lo32($1), hi32($1), lo32($2), hi32($2), lo32($3), hi32($3))
			} else if (FMT == "in_w") {
				#	8-hex int into single slot, stride 8
				emit8(strtonum("0x"$1), 0, 0, 0, 0, 0)
			} else if (FMT == "in_l") {
				#	16-hex int into two slots, stride 8
				emit8(lo32($1), hi32($1), 0, 0, 0, 0)
			}
		}
	' "$cd/in.txt" > "$cd/vectors.hex"

	cat "$FW_HEX" "$cd/vectors.hex" > "$cd/combined.hex"

	local out_words=$(( n * 2 ))			# 2 ram-words per record
	local max_cyc=$(( 400 * n + 200000 ))	# generous for f64 multi-cycle ops

	"$FP_TB" \
		+hex="$cd/combined.hex" \
		+tohost=8000 \
		+max_cycles="$max_cyc" \
		+vec_out="$cd/out.hex" \
		+vec_out_start="$OUT_WORD_START" \
		+vec_out_words="$out_words" \
		> "$cd/sim.log" 2>&1
	if ! grep -q '^\[HTIF\] exit 0' "$cd/sim.log"; then
		echo "[fp-test] chunk $ci/$NCHUNKS sim did not exit cleanly:" >&2
		tail -10 "$cd/sim.log" | sed 's/^/  /' >&2
		touch "$cd/FAIL"
		return 1
	fi

	#	Parse out.hex: 2 ram-words per record. word0 = (r_hi<<32)|r_lo,
	#	word1 = (0<<32)|flags. Emit "<result_formatted> <flags>" per line.
	gawk -v FMT="$OUTFMT" '
		BEGIN { line_in_rec = 0 }
		/^\/\// { next }
		/^@/    { next }
		{
			h = $1
			while (length(h) < 16) h = "0" h
			hi = substr(h, 1, 8); lo = substr(h, 9, 8)
			if      (line_in_rec == 0) { r_hi = hi; r_lo = lo }
			else if (line_in_rec == 1) { flags = lo }
			line_in_rec++
			if (line_in_rec == 2) {
				fl2 = sprintf("%02x", strtonum("0x" flags) % 32)
				if      (FMT == "r_f32")  printf "%s %s\n", r_lo, fl2
				else if (FMT == "r_f64")  printf "%s%s %s\n", r_hi, r_lo, fl2
				else if (FMT == "r_i64")  printf "%s%s %s\n", r_hi, r_lo, fl2
				else if (FMT == "r_bool") printf "%d %s\n",
					(strtonum("0x" r_lo) != 0 ? 1 : 0), fl2
				line_in_rec = 0
			}
		}
	' "$cd/out.hex" > "$cd/results.txt"

	#	Join operand line(s) from chunk with the result+flags line.
	paste -d ' ' "$cd/in.txt" "$cd/results.txt" > "$cd/joined.txt"
}

#	Dispatch chunks with at most PARALLEL in flight.
launched=0
for ci in $(seq 0 $((NCHUNKS - 1))); do
	run_one_chunk "$ci" &
	launched=$((launched + 1))
	if (( launched >= PARALLEL )); then
		wait -n
		launched=$((launched - 1))
	fi
done
wait

if compgen -G "$WORK/chunks/*/FAIL" > /dev/null; then
	echo "[fp-test] one or more chunks failed; aborting"
	exit 2
fi

#	Concat per-chunk joined.txt in index order.
: > "$WORK/results.txt"
for ci in $(seq 0 $((NCHUNKS - 1))); do
	cat "$WORK/chunks/$ci/joined.txt" >> "$WORK/results.txt"
done

NRES=$(wc -l < "$WORK/results.txt")
if (( NRES != NTOTAL )); then
	echo "[fp-test] record-count mismatch: gen=$NTOTAL parsed=$NRES"
	exit 2
fi

"$TF_VER" $VER_OPTS $RM_FLAG "$TF_OP" < "$WORK/results.txt" \
	> "$WORK/ver.out" 2> "$WORK/ver.err" || true

NMISS=$(grep -c '=>' "$WORK/ver.out" || true)
echo "[fp-test] $TF_OP: $NTOTAL vectors, $NMISS error lines reported by testfloat_ver"
tail -2 "$WORK/ver.err" | sed 's/^/  /'

exit 0
