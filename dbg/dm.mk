# karudbg DM/ROM tests. Included by the root Makefile.
DBG_DIR ?= $(BUILD)/dbg
DBG_DM_SRCS = dbg/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v

.PHONY: dbg-sba-unit-test
dbg-sba-unit-test:
	mkdir -p $(DBG_DIR)
	iverilog -g2012 -s tb_sba -o $(DBG_DIR)/tb_sba.vvp \
	  test/dbg/tb_sba.sv dbg/karudbg_sba.v
	vvp $(DBG_DIR)/tb_sba.vvp | tee $(DBG_DIR)/sba-unit.log
	grep -q 'karudbg SBA 32-bit: PASS' $(DBG_DIR)/sba-unit.log
	iverilog -g2012 -DTEST_SBA64 -s tb_sba -o $(DBG_DIR)/tb_sba64.vvp \
	  test/dbg/tb_sba.sv dbg/karudbg_sba.v
	vvp $(DBG_DIR)/tb_sba64.vvp | tee $(DBG_DIR)/sba64-unit.log
	grep -q 'karudbg SBA 64-bit: PASS' $(DBG_DIR)/sba64-unit.log
	iverilog -g2012 -Idbg -s tb_sba_dm -o $(DBG_DIR)/tb_sba_dm.vvp \
	  test/dbg/tb_sba_dm.sv $(DBG_DM_SRCS)
	vvp $(DBG_DIR)/tb_sba_dm.vvp | tee $(DBG_DIR)/sba-dmi-unit.log
	grep -q 'karudbg SBA DMI: PASS' $(DBG_DIR)/sba-dmi-unit.log
	python3 test/dbg/negative_sba.py --out $(DBG_DIR)/negative-sba
	verilator --lint-only -Wall -Idbg -DKARU_DBG_SBA --top-module karudbg $(DBG_DM_SRCS)
	iverilog -g2001 -Idbg -DKARU_DBG_SBA -s karudbg \
	  -o $(DBG_DIR)/dm-sba-parse.vvp $(DBG_DM_SRCS)

.PHONY: dbg-unit-test dbg-autoexec-test dbg-rom-generate dbg-rom-check dbg-dm-lint
dbg-autoexec-test:
	mkdir -p $(DBG_DIR)
	iverilog -g2012 -Idbg -DTEST_AUTOEXEC -DKARU_DBG_AUTOEXEC -s tb_dm \
	  -o $(DBG_DIR)/tb_autoexec.vvp test/dbg/tb_dm.sv $(DBG_DM_SRCS)
	vvp $(DBG_DIR)/tb_autoexec.vvp | tee $(DBG_DIR)/autoexec-unit.log
	grep -q 'karudbg autoexec: PASS' $(DBG_DIR)/autoexec-unit.log
	verilator --lint-only -Wall -Idbg -DKARU_DBG_AUTOEXEC --top-module karudbg $(DBG_DM_SRCS)

dbg-unit-test:
	mkdir -p $(DBG_DIR)
	iverilog -g2012 -Idbg -s tb_dm -o $(DBG_DIR)/tb_dm.vvp test/dbg/tb_dm.sv $(DBG_DM_SRCS)
	vvp $(DBG_DIR)/tb_dm.vvp | tee $(DBG_DIR)/dm-unit.log
	grep -q 'karudbg DM unit: PASS' $(DBG_DIR)/dm-unit.log
	@if vvp $(DBG_DIR)/tb_dm.vvp +negative_resume > $(DBG_DIR)/dm-negative-resume.log 2>&1; then \
	  echo 'missing-RESUMING negative control did not fail'; exit 1; fi
	grep -q 'resume acknowledged before ROM RESUMING' $(DBG_DIR)/dm-negative-resume.log
	# Mutant: dmactive=0 acknowledged at once while a command is busy (S8).
	mkdir -p $(DBG_DIR)/dm-negative-deact
	sed 's/end else if (busy) begin/end else if (1'"'"'b0) begin/' dbg/karudbg.v \
	  > $(DBG_DIR)/dm-negative-deact/karudbg.v
	! cmp -s dbg/karudbg.v $(DBG_DIR)/dm-negative-deact/karudbg.v
	iverilog -g2012 -Idbg -s tb_dm -o $(DBG_DIR)/dm-negative-deact/tb_dm.vvp test/dbg/tb_dm.sv \
	  $(DBG_DIR)/dm-negative-deact/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v
	@if vvp $(DBG_DIR)/dm-negative-deact/tb_dm.vvp > $(DBG_DIR)/dm-negative-deact.log 2>&1; then \
	  echo 'early-deactivation negative control did not fail'; exit 1; fi
	grep -q 'deactivation completed with a busy command engine' $(DBG_DIR)/dm-negative-deact.log

dbg-rom-generate:
	python3 dbg/rom/gen_rom.py --xchain $(XCHAIN) --build-dir $(DBG_DIR)/rom

dbg-rom-check:
	python3 dbg/rom/gen_rom.py --xchain $(XCHAIN) --build-dir $(DBG_DIR)/rom --check

dbg-dm-lint:
	mkdir -p $(DBG_DIR)
	verilator --lint-only -Wall -Idbg --top-module karudbg $(DBG_DM_SRCS)
	iverilog -g2001 -Idbg -s karudbg -o $(DBG_DIR)/dm-parse.vvp $(DBG_DM_SRCS)

# S10 (security review 2026-11-15): ndmreset_o feeds asynchronous reset
# synchronizers in integrations, so it must be one flop's Q, not a
# combinational term. Negative control: the pre-fix AND with dmactive.
.PHONY: dbg-ndmreset-flop-test
dbg-ndmreset-flop-test:
	mkdir -p $(DBG_DIR)/ndmreset-flop/mutant
	python3 test/dbg/check_output_flop.py --top karudbg --port ndmreset_o \
	  --out $(DBG_DIR)/ndmreset-flop/base -I dbg $(DBG_DM_SRCS)
	python3 test/dbg/check_output_flop.py --top karudbg --port ndmreset_o \
	  --out $(DBG_DIR)/ndmreset-flop/full -I dbg -D KARU_DBG_SBA -D KARU_DBG_AUTOEXEC $(DBG_DM_SRCS)
	sed 's/^    assign ndmreset_o = ndmreset_q;/    assign ndmreset_o = dmactive_q \&\& ndmreset_q;/' \
	  dbg/karudbg.v > $(DBG_DIR)/ndmreset-flop/mutant/karudbg.v
	! cmp -s dbg/karudbg.v $(DBG_DIR)/ndmreset-flop/mutant/karudbg.v
	@if python3 test/dbg/check_output_flop.py --top karudbg --port ndmreset_o \
	  --out $(DBG_DIR)/ndmreset-flop/mutant -I dbg $(DBG_DIR)/ndmreset-flop/mutant/karudbg.v \
	  dbg/karudbg_rom.v dbg/karudbg_sba.v > $(DBG_DIR)/ndmreset-flop/mutant.log 2>&1; then \
	  cat $(DBG_DIR)/ndmreset-flop/mutant.log; echo 'combinational ndmreset_o mutant not detected'; exit 1; fi
	grep -q 'FAIL karudbg.ndmreset_o: not driven directly by one flop' $(DBG_DIR)/ndmreset-flop/mutant.log
	@echo 'PASS ndmreset_o single-flop check, combinational mutant detected'
