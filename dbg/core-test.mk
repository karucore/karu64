# Real core integration, bounded directed DMI/Program Buffer tests.
DBG_CORE_DIR ?= $(BUILD)/dbg/core
DBG_CORE_BIN = $(DBG_CORE_DIR)/Vtb_dbg_core
DBG_CORE_FLAGS ?= -DKARU_NO_V
DBG_CORE_SIM_FLAGS ?= --unroll-count 1 --output-split 10000
DBG_CORE_RTL = dbg/karudbg_bus.v dbg/karudbg_sba.v dbg/karudbg_core.v dbg/karudbg_axi.v dbg/karudbg.v dbg/karudbg_rom.v $(CORE_RTL) rtl/karu_sv39.v $(ZVK_RTL)
$(DBG_CORE_BIN): test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv test/dbg/sba_core_tests.vh $(DBG_CORE_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv test/dbg/*.vh) dbg/core-test.mk
	mkdir -p $(DBG_CORE_DIR)
	verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG $(DBG_CORE_FLAGS) $(LINT_W) \
	  --Mdir $(DBG_CORE_DIR) --top-module tb_dbg_core test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)

.PHONY: dbg-core-test dbg-core-four-state-test dbg-core-profile-test dbg-context-test dbg-core-aw-wait-test dbg-core-negative-test
dbg-core-test: $(DBG_CORE_BIN)
	$(DBG_CORE_BIN) > $(DBG_CORE_DIR)/run.log 2>&1
	cat $(DBG_CORE_DIR)/run.log
	grep -q 'karudbg actual core: PASS' $(DBG_CORE_DIR)/run.log

dbg-core-profile-test:
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/core-profile \
	  DBG_CORE_FLAGS='-DKARU_RVA23S64 -DKARU_ZVK -DKARU_KECCAK -DKARU_SMCNTRPMF -DKARU_ICACHE -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64' dbg-core-test

dbg-context-test: dbg-core-profile-test

dbg-core-aw-wait-test:
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/core-aw-wait \
	  DBG_CORE_FLAGS='-DKARU_NO_F -DTEST_AW_WAIT_WVALID' dbg-core-test

dbg-core-four-state-test:
	mkdir -p $(BUILD)/dbg/core-four-state
	timeout 120 iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_NO_F -DKARU_ASIC \
	  -s tb_dbg_core -o $(BUILD)/dbg/core-four-state/test.vvp \
	  test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)
	timeout 120 vvp $(BUILD)/dbg/core-four-state/test.vvp > $(BUILD)/dbg/core-four-state/run.log 2>&1
	cat $(BUILD)/dbg/core-four-state/run.log
	grep -q 'karudbg actual core: PASS' $(BUILD)/dbg/core-four-state/run.log

dbg-core-negative-test:
	python3 test/dbg/test_core_negative.py --build-dir $(BUILD)/dbg/core-negative --jobs 2

.PHONY: dbg-sba-core-test
dbg-sba-core-test:
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/core-sba \
	  DBG_CORE_FLAGS='-DKARU_NO_F -DKARU_ICACHE -DKARU_DBG_SBA -DTEST_SBA_PROBE' \
	  $(BUILD)/dbg/core-sba/Vtb_dbg_core
	$(BUILD)/dbg/core-sba/Vtb_dbg_core > $(BUILD)/dbg/core-sba/run.log 2>&1
	cat $(BUILD)/dbg/core-sba/run.log
	grep -q 'karudbg focused SBA probe: PASS' $(BUILD)/dbg/core-sba/run.log

# Combined extensions retain the ordinary debug and application-state tests.
.PHONY: dbg-core-full-test dbg-core-full-four-state-test
dbg-core-full-test:
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/core-full \
	  DBG_CORE_FLAGS='-DKARU_DBG_FULL -DKARU_RVA23S64 -DKARU_ZVK -DKARU_KECCAK -DKARU_SMCNTRPMF -DKARU_ICACHE -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64' dbg-core-test

dbg-core-full-four-state-test:
	mkdir -p $(BUILD)/dbg/core-full-four-state
	timeout 120 iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_FULL -DKARU_NO_F -DKARU_ASIC \
	  -s tb_dbg_core -o $(BUILD)/dbg/core-full-four-state/test.vvp \
	  test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)
	timeout 120 vvp $(BUILD)/dbg/core-full-four-state/test.vvp > $(BUILD)/dbg/core-full-four-state/run.log 2>&1
	cat $(BUILD)/dbg/core-full-four-state/run.log
	grep -q 'karudbg actual core: PASS' $(BUILD)/dbg/core-full-four-state/run.log
