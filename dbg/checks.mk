# Aggregate gates exclude board access and synthesis; run those explicitly.
DBG_ALL_RTL = $(filter %.v,$(shell cat dbg/karudbg.f))
DBG_LINT_FLAGS = -Irtl -Idbg -DKARU_DBG -DKARU_RVA23S64 -DKARU_ICACHE \
 -DKARU_ZVK -DKARU_KECCAK -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE

.PHONY: dbg-lint dbg-rom-test dbg-memory-test dbg-jtag-test dbg-gdb-test \
 dbg-test dbg-functional-gates
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

dbg-functional-gates: axi-prot-test axi-prot-debug-test dbg-unit-test dbg-rom-test \
 dbg-memory-test dbg-core-profile-test dbg-core-four-state-test \
 dbg-core-negative-test dbg-transport-negative-test dbg-jtag-test \
 dbg-openocd-negative-test dbg-translation-test dbg-gdb-test dbg-lint \
 dbg-bscan-test dbg-bscan-core-test dbg-bscan-gdb-test dbg-bscan-translation-test

DBG_GATE_JOBS ?= 3
dbg-test:
	python3 test/dbg/run_validation.py --out $(BUILD)/dbg --jobs $(DBG_GATE_JOBS)
