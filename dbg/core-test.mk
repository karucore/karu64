# Real core integration, bounded directed DMI/Program Buffer tests.
DBG_CORE_DIR ?= $(BUILD)/dbg/core
DBG_CORE_BIN = $(DBG_CORE_DIR)/Vtb_dbg_core
DBG_CORE_FLAGS ?= -DKARU_NO_V
DBG_CORE_SIM_FLAGS ?= --unroll-count 1 --output-split 10000
DBG_CORE_RTL = dbg/karudbg_auth.v dbg/karudbg_island.v dbg/karudbg_bus.v dbg/karudbg_sba.v dbg/karudbg_core.v dbg/karudbg_axi.v dbg/karudbg.v dbg/karudbg_rom.v $(CORE_RTL) rtl/karu_sv39.v $(ZVK_RTL)
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

# Run-control legality on the real core: stepped WFI keeps its U/S/TW and
# VS/VU/VTW traps, and only SYSTEM-opcode WRS skips the FENCE handshake.
DBG_RUN_CONTROL_DIR ?= $(BUILD)/dbg/run-control
DBG_RUN_CONTROL_FLAGS ?= -DKARU_NO_V -DKARU_H
$(DBG_RUN_CONTROL_DIR)/Vtb_run_control: test/dbg/tb_run_control.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv) dbg/core-test.mk
	mkdir -p $(DBG_RUN_CONTROL_DIR)
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG $(DBG_RUN_CONTROL_FLAGS) $(LINT_W) \
	  --Mdir $(DBG_RUN_CONTROL_DIR) --top-module tb_run_control test/dbg/tb_run_control.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)

.PHONY: dbg-run-control-test
dbg-run-control-test: $(DBG_RUN_CONTROL_DIR)/Vtb_run_control
	timeout 300 $< > $(DBG_RUN_CONTROL_DIR)/run.log 2>&1
	cat $(DBG_RUN_CONTROL_DIR)/run.log
	grep -q 'karudbg run-control legality: PASS' $(DBG_RUN_CONTROL_DIR)/run.log
	# Mutant: the pre-fix debug-page router, which selects responses by the
	# owner flag alone, with its local checks disabled. The forged
	# debug-page cases must catch it.
	mkdir -p $(DBG_RUN_CONTROL_DIR)/mut-router
	sed -e 's/assign c_imem_rvalid=im_out \&\& (im_owner ? i_rvalid : imem_rvalid);/assign c_imem_rvalid=im_owner ? i_rvalid : imem_rvalid;/' \
	    -e 's/assign imem_rready=c_imem_rready \&\& im_out \&\& !im_owner;/assign imem_rready=c_imem_rready \&\& !im_owner;/' \
	    -e 's/assign c_dmem_rvalid=dr_out \&\& (dr_owner ? d_rvalid : x_dmem_rvalid);/assign c_dmem_rvalid=dr_owner ? d_rvalid : x_dmem_rvalid;/' \
	    -e 's/assign x_dmem_rready=c_dmem_rready \&\& dr_out \&\& !dr_owner;/assign x_dmem_rready=c_dmem_rready \&\& !dr_owner;/' \
	    -e 's/[$$]fatal(1, "karudbg_core:/$$display("disabled karudbg_core:/' \
	    dbg/karudbg_core.v > $(DBG_RUN_CONTROL_DIR)/mut-router/karudbg_core.v
	test "$$(diff dbg/karudbg_core.v $(DBG_RUN_CONTROL_DIR)/mut-router/karudbg_core.v | grep -c '^>')" = 6
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG $(DBG_RUN_CONTROL_FLAGS) $(LINT_W) \
	  --Mdir $(DBG_RUN_CONTROL_DIR)/mut-router/obj --top-module tb_run_control test/dbg/tb_run_control.sv test/dbg/karudbg_test_ram.sv \
	  $(filter-out dbg/karudbg_core.v,$(DBG_CORE_RTL)) $(DBG_RUN_CONTROL_DIR)/mut-router/karudbg_core.v > $(DBG_RUN_CONTROL_DIR)/mut-router/build.log 2>&1
	@if timeout 300 $(DBG_RUN_CONTROL_DIR)/mut-router/obj/Vtb_run_control > $(DBG_RUN_CONTROL_DIR)/mut-router/run.log 2>&1; then \
	  echo 'debug-page router mutant NOT detected'; exit 1; fi
	grep -Eq 'DEBUG_PAGE_FORGED_[A-Z]*: (forged debug-page response reached the hart)|hart did not park' $(DBG_RUN_CONTROL_DIR)/mut-router/run.log
	@echo "detected debug-page router mutant: $$(grep -Eom1 'DEBUG_PAGE_FORGED_[A-Z]*: forged[a-z -]*|hart did not park' $(DBG_RUN_CONTROL_DIR)/mut-router/run.log)"
