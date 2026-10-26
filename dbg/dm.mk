# karudbg DM/ROM tests. Included by the root Makefile.
DBG_DIR ?= $(BUILD)/dbg
DBG_DM_SRCS = dbg/karudbg.v dbg/karudbg_rom.v

.PHONY: dbg-unit-test dbg-rom-generate dbg-rom-check dbg-dm-lint
dbg-unit-test:
	mkdir -p $(DBG_DIR)
	iverilog -g2012 -Idbg -s tb_dm -o $(DBG_DIR)/tb_dm.vvp test/dbg/tb_dm.sv $(DBG_DM_SRCS)
	vvp $(DBG_DIR)/tb_dm.vvp | tee $(DBG_DIR)/dm-unit.log
	grep -q 'karudbg DM unit: PASS' $(DBG_DIR)/dm-unit.log
	@if vvp $(DBG_DIR)/tb_dm.vvp +negative_resume > $(DBG_DIR)/dm-negative-resume.log 2>&1; then \
	  echo 'missing-RESUMING negative control did not fail'; exit 1; fi
	grep -q 'resume acknowledged before ROM RESUMING' $(DBG_DIR)/dm-negative-resume.log

dbg-rom-generate:
	python3 dbg/rom/gen_rom.py --xchain $(XCHAIN) --build-dir $(DBG_DIR)/rom

dbg-rom-check:
	python3 dbg/rom/gen_rom.py --xchain $(XCHAIN) --build-dir $(DBG_DIR)/rom --check

dbg-dm-lint:
	mkdir -p $(DBG_DIR)
	verilator --lint-only -Wall -Idbg --top-module karudbg $(DBG_DM_SRCS)
	iverilog -g2001 -Idbg -s karudbg -o $(DBG_DIR)/dm-parse.vvp $(DBG_DM_SRCS)
