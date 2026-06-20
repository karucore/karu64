#	flow/syn/Makefile
#	Convenience entry points for the karu64 open-source synth flow.
#	Real work is in syn_yosys.sh and the tcl/ scripts.

.PHONY: synth ibex area-matrix sweep depth clean help

help:
	@echo "make synth           run yosys + opensta, leave a timestamped tree in syn_out/"
	@echo "make synth CLK=3500  retarget the clock to 3500 ps (default 4000)"
	@echo "make ibex           synth Ibex small with the same Nangate/Yosys abc-fast flags"
	@echo "make ibex IBEX_CONFIG=maxperf   synth another Ibex preset"
	@echo "make area-matrix    run area-only Karu feature/knob matrix; see AREA_MATRIX.md"
	@echo "make area-matrix CONFIGS=\"imac_m4d64 rv64gc_m4d64\"   run selected rows"
	@echo "make area-matrix JOBS=4 CONFIGS=\"imac_m4d64 rv64gc_m4d64\"   run selected scalar rows in parallel"
	@echo "make area-matrix KARU_NOSHARE=1 JOBS=2 CONFIGS=\"rv64gcv_default rv64gcv_zvkned rv64gcv_zvkg\"   skip SAT sharing for vector/Zvk rows"
	@echo "make sweep           synth IMAC / IMAFC / IMAFDC / IMAFDCV; tabulate kGE (+ shallow depth)"
	@echo "make sweep CONFIGS=\"imac imafc\"   sweep a subset"
	@echo "make depth           FAST per-module logic depth (no abc/liberty); all modules + per-config max"
	@echo "make depth MODULES=\"karu_fdiv karu_varith\"   probe a subset"
	@echo "make clean           remove syn_out/"
	@echo
	@echo "First-time setup:"
	@echo "  make synth"

#	make synth CLK=<period_ps>
ifeq ($(origin CLK), command line)
synth: export KARU_CLK_PS = $(CLK)
endif

synth:
	@test -f syn_setup.sh || (echo "syn_setup.sh missing"; exit 1)
	./syn_yosys.sh

ibex:
	@test -f syn_setup.sh || (echo "syn_setup.sh missing"; exit 1)
	./ibex_yosys.sh

#	make area-matrix [CONFIGS="..."] [PER_TIMEOUT=7200]
area-matrix: export CONFIGS := $(CONFIGS)
area-matrix: export PER_TIMEOUT := $(PER_TIMEOUT)
area-matrix: export JOBS := $(JOBS)
area-matrix: export KARU_NOSHARE := $(KARU_NOSHARE)
area-matrix: export MATRIX_OUT_DIR := $(MATRIX_OUT_DIR)
area-matrix: export MATRIX_FILE := $(MATRIX_FILE)
area-matrix: export MATRIX_ROWS := $(MATRIX_ROWS)
area-matrix: export NAND2_UM2 := $(NAND2_UM2)
area-matrix:
	@test -f syn_setup.sh || (echo "syn_setup.sh missing"; exit 1)
	./syn_area_matrix.sh

#	make sweep [CONFIGS="imac imafc imafdc imafdcv"] [BASE_DEFINES="..."]
sweep:
	@test -f syn_setup.sh || (echo "syn_setup.sh missing"; exit 1)
	./syn_sweep.sh

#	make depth [MODULES="..."] [DEFINES="..."] [DEPTH_AIG=1] -- no liberty needed
depth:
	./syn_depth.sh

clean:
	$(RM) -r syn_out
