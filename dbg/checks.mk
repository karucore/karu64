# Aggregate gates exclude board access and synthesis; run those explicitly.
DBG_ALL_RTL = $(filter %.v,$(shell cat dbg/karudbg.f))
DBG_LINT_FLAGS = -Irtl -Idbg -DKARU_DBG -DKARU_RVA23S64 -DKARU_ICACHE \
 -DKARU_ZVK -DKARU_KECCAK -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE

.PHONY: dbg-lint dbg-rom-test dbg-memory-test dbg-jtag-test dbg-gdb-test \
 dbg-test dbg-functional-gates dbg-ooc-reset-constraints-test

dbg-ooc-reset-constraints-test:
	tclsh test/dbg/test_ooc_reset_constraints.tcl
dbg-lint:
	mkdir -p $(BUILD)/dbg
	python3 flow/asic/lint_decl.py $(DBG_ALL_RTL)
	verilator --lint-only $(DBG_LINT_FLAGS) $(LINT_W) \
	  --Mdir $(BUILD)/dbg/lint --top-module karudbg_top -f dbg/karudbg.f
	timeout 120 iverilog -g2001 -DSYNTHESIS -DKARU_ASIC $(DBG_LINT_FLAGS) \
	  -s karudbg_top -o $(BUILD)/dbg/strict-parse.vvp -c dbg/karudbg.f \
	  rtl/karu_vrf_assert.sv

dbg-rom-test: dbg-rom-check dbg-core-test
dbg-memory-test: dbg-axi-test dbg-core-aw-wait-test
dbg-jtag-test: dbg-dtm-test dbg-openocd-transport-test dbg-openocd-core-test

DBG_GDB ?= $(XCHAIN)gdb
$(BUILD)/dbg/gdb-target.elf: test/dbg/gdb_target.S
	mkdir -p $(BUILD)/dbg
	$(XCHAIN)gcc -g -march=rv64gc -mabi=lp64d -nostdlib -static \
	  -Wl,-Ttext=0x80000000,--no-relax -o $@ $<

dbg-gdb-test: dbg-openocd-build $(DBG_OPENOCD_MODEL) $(BUILD)/dbg/gdb-target.elf
	python3 test/dbg/run_gdb.py --model $(DBG_OPENOCD_MODEL) \
	  --openocd $(DBG_OPENOCD_PATCHED) --gdb $(DBG_GDB) \
	  --elf $(BUILD)/dbg/gdb-target.elf --out $(BUILD)/dbg/gdb

dbg-functional-gates: dbg-trigger-unit-test dbg-trigger-vector-test dbg-trigger-four-state-test \
 dbg-trigger-core-test dbg-trigger-profile-test dbg-trigger-haccess-test dbg-trigger-negative-test dbg-trigger-spike-test \
 dbg-core-full-test dbg-core-full-four-state-test dbg-isa-runner-test axi-prot-test axi-prot-debug-test dbg-unit-test dbg-autoexec-test dbg-sba-unit-test \
 dbg-autoexec-core-test dbg-autoexec-gdb-test dbg-sba-bus-test dbg-sba-core-test dbg-sba-core-negative-test \
 dbg-full-openocd-test dbg-trigger-openocd-test dbg-trigger-gdb-test dbg-rom-test \
 dbg-memory-test dbg-core-profile-test dbg-core-four-state-test \
 dbg-core-negative-test dbg-transport-negative-test dbg-jtag-test \
 dbg-openocd-negative-test dbg-translation-test dbg-gdb-test dbg-lint \
 dbg-bscan-test dbg-bscan-core-test dbg-bscan-gdb-test dbg-bscan-translation-test \
 dbg-ooc-reset-constraints-test dbg-runtime-div-audit dbg-config-matrix-test dbg-asic-random-test \
 dbg-measurements-collector-test dbg-bscan-full-test

dbg-functional-gates: dbg-sba-invariant-test dbg-sba-review-negative-test \
 dbg-sba-core-locked-test dbg-sba-core-four-state-test \
 dbg-trigger-invariant-test dbg-trigger-review-test

# 2026-11-15 security-review regressions (S7-S13); see
# doc/security-review-2026-11-15.md. lsu-aw-w-test, dbg-bscan-truncate-test,
# dbg-sba-xbar-test and dbg-ndmreset-flop-test run their own mutant controls.
# nomem-aw-w-isa-test and dbg-run-control-test are positive end-to-end runs;
# their discrimination was shown once against pre-fix RTL, and INV41 has
# driven-state controls in dbg-trigger-invariant-test.
dbg-functional-gates: lsu-aw-w-test nomem-aw-w-isa-test dbg-bscan-truncate-test \
 dbg-sba-xbar-test dbg-run-control-test dbg-ndmreset-flop-test

# Debug authentication (doc/debug-auth-plan.md A1, contract
# doc/debug-auth-contract.md).
dbg-functional-gates: dbg-auth-test
dbg-functional-gates: dbg-auth-sba-revoke-test
# The access permissions of a core with authentication: the island SRAM and
# the Debug Module's page are inside the boot ROM's span and are not ROM.
# Checked through the address translator, HLVX included, with a control.
dbg-functional-gates: sv39-auth-pma-test

# 2026-11-16 board campaign follow-ups (dbg/BOARD_ACCEPTANCE.md): the FPGA
# UART receive path (two mutants), the board harness self-test, and the
# rehearsal of the board autoexec case on the simulated target with RTL
# negative controls.
dbg-functional-gates: uart-rx-test dbg-board-harness-test dbg-board-rehearsal-test

# Software reboot of the VCU118 SoC (doc/fpga.md): the system-control
# register on the DDR simulation top, with seven decode mutants. The reset
# sequencer, its single-flop output and the board-top wiring are checked by
# dbg-fpga-reset-test (part of dbg-bscan-test). sbi-reboot-test, which uses
# karudeb's OpenSBI and device tree, is outside this hashed gate.
dbg-functional-gates: ddr-reboot-test

# Zkr entropy source (doc/fpga.md, "Entropy source"): the entropy block with
# driven symbols and its one-mechanism mutants, then the seed access table,
# mseccfg, word delivery, the custom CSRs and the strap on the core, with and
# without H, and the access-rule mutants. image-boot-test, which boots
# karudeb's OpenSBI with the Zkr device tree, is outside this hashed gate.
dbg-functional-gates: entropy-test zkr-test zkr-loop-test
# The GetNoise capture payload on the same bench, the offline analysis on
# synthetic model data, and the capture phase against a stand-in debugger.
dbg-functional-gates: dbg-getnoise-test
# Burst capture of the FPGA entropy source (doc/zkr-followup-plan.md, Z1 to
# Z3): the capture block with the noise source and the entropy block, and
# its one-mechanism mutants; its registers through the DDR SoC's bus decode,
# with decode mutants; the burst payload and phase on that SoC simulation;
# and the analysis of burst captures on generated data with known parameters.
dbg-functional-gates: noise-burst-test ddr-noise-burst-test dbg-getnoise-burst-test dbg-burst-analysis-test

DBG_GATE_JOBS ?= 3
dbg-test:
	python3 test/dbg/run_validation.py --out $(BUILD)/dbg --jobs $(DBG_GATE_JOBS)

.PHONY: dbg-config-matrix-test
dbg-config-matrix-test:
	python3 test/dbg/check_config_matrix.py --out $(BUILD)/dbg/config-matrix --jobs 2

.PHONY: dbg-asic-random-test
dbg-asic-random-test:
	$(MAKE) DBG_JOBS=6 DBG_CORE_DIR=$(BUILD)/dbg/core-extensions-random \
	  DBG_CORE_FLAGS='-DKARU_RVA23S64 -DKARU_ZVK -DKARU_KECCAK -DKARU_SMCNTRPMF -DKARU_ICACHE -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_DBG_FULL -DKARU_ASIC -DTEST_TRIGGER_PROBE -DTEST_SBA_PROBE -DTEST_EXTENSION_PROBE' \
	  DBG_CORE_SIM_FLAGS='--unroll-count 1 --x-initial unique --x-assign unique --output-split 10000' \
	  $(BUILD)/dbg/core-extensions-random/Vtb_dbg_core
	python3 test/dbg/run_random_extensions.py \
	  --model $(BUILD)/dbg/core-extensions-random/Vtb_dbg_core --out $(BUILD)/dbg/asic-random
