# Sdtrig address-match bank and architectural core tests.
.PHONY: dbg-trigger-unit-test dbg-trigger-core-test dbg-trigger-profile-test
dbg-trigger-unit-test:
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_RVA23S64 -s tb_trigger -o $(BUILD)/dbg/tb_trigger.vvp test/dbg/tb_trigger.sv rtl/karu_trigger.v
	vvp $(BUILD)/dbg/tb_trigger.vvp | tee $(BUILD)/dbg/trigger-unit.log
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_RVA23S64 -DTEST_FOUR_TRIGGERS -s tb_trigger -o $(BUILD)/dbg/tb_trigger4.vvp test/dbg/tb_trigger.sv rtl/karu_trigger.v
	vvp $(BUILD)/dbg/tb_trigger4.vvp | tee $(BUILD)/dbg/trigger4-unit.log

dbg-trigger-core-test:
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/trigger-probe DBG_CORE_FLAGS='-DKARU_NO_V -DKARU_DBG_TRIGGERS -DTEST_TRIGGER_PROBE' $(BUILD)/dbg/trigger-probe/Vtb_dbg_core
	$(BUILD)/dbg/trigger-probe/Vtb_dbg_core > $(BUILD)/dbg/trigger-probe/run.log 2>&1
	cat $(BUILD)/dbg/trigger-probe/run.log
	grep -q 'karudbg focused trigger probe: PASS' $(BUILD)/dbg/trigger-probe/run.log

dbg-trigger-profile-test:
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/trigger-profile DBG_CORE_FLAGS='-DKARU_RVA23S64 -DKARU_ICACHE -DKARU_DBG_TRIGGERS -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DTEST_TRIGGER_PROBE' $(BUILD)/dbg/trigger-profile/Vtb_dbg_core
	$(BUILD)/dbg/trigger-profile/Vtb_dbg_core > $(BUILD)/dbg/trigger-profile/run.log 2>&1
	cat $(BUILD)/dbg/trigger-profile/run.log
	grep -q 'karudbg focused trigger probe: PASS' $(BUILD)/dbg/trigger-profile/run.log

.PHONY: dbg-trigger-vector-test
dbg-trigger-vector-test:
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_TRIGGERS -s tb_vlsu_watch -o $(BUILD)/dbg/tb_vlsu_watch.vvp test/dbg/tb_vlsu_watch.sv rtl/karu_vlsu.v rtl/karu_vlsu_buf.v
	timeout 30 vvp $(BUILD)/dbg/tb_vlsu_watch.vvp | tee $(BUILD)/dbg/trigger-vector-unit.log

DBG_TRIGGER_IV_FLAGS ?= -DKARU_NO_F
DBG_TRIGGER_IV_DIR ?= $(BUILD)/dbg/trigger-four-state
DBG_TRIGGER_IV_TIMEOUT ?= 240
.PHONY: dbg-trigger-four-state-test
dbg-trigger-four-state-test:
	mkdir -p $(DBG_TRIGGER_IV_DIR)
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_TRIGGERS $(DBG_TRIGGER_IV_FLAGS) -DKARU_ASIC -DTEST_TRIGGER_PROBE -s tb_dbg_core -o $(DBG_TRIGGER_IV_DIR)/test.vvp test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL) rtl/karu_vrf_assert.sv
	timeout $(DBG_TRIGGER_IV_TIMEOUT) vvp $(DBG_TRIGGER_IV_DIR)/test.vvp > $(DBG_TRIGGER_IV_DIR)/run.log 2>&1
	cat $(DBG_TRIGGER_IV_DIR)/run.log
	grep -q 'karudbg focused trigger probe: PASS' $(DBG_TRIGGER_IV_DIR)/run.log

.PHONY: dbg-trigger-negative-test
dbg-trigger-negative-test:
	python3 test/dbg/negative_trigger.py --out $(BUILD)/dbg/trigger-negative

DBG_SPIKE ?= spike
.PHONY: dbg-trigger-spike-test
dbg-trigger-spike-test: $(BUILD)/dbg/gdb-target.elf
	python3 test/dbg/run_spike_triggers.py --spike $(DBG_SPIKE) --openocd $(OPENOCD) --elf $< --out $(BUILD)/dbg/spike-triggers

.PHONY: dbg-trigger-haccess-test
dbg-trigger-haccess-test:
	$(MAKE) dbg-trigger-four-state-test DBG_TRIGGER_IV_DIR=$(BUILD)/dbg/trigger-haccess-four-state DBG_TRIGGER_IV_FLAGS='-DKARU_RVA23S64 -DKARU_ICACHE -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DTEST_TRIGGER_HACCESS'

.PHONY: dbg-trigger-review-test
dbg-trigger-review-test:
	mkdir -p $(BUILD)/dbg/trigger-review
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_FULL -DKARU_RVA23S64 -DKARU_ICACHE -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_ASIC -DTEST_TRIGGER_REVIEW -DTEST_TRIGGER_PROBE -s tb_dbg_core -o $(BUILD)/dbg/trigger-review/test.vvp test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL) rtl/karu_vrf_assert.sv
	timeout $(DBG_TRIGGER_IV_TIMEOUT) vvp $(BUILD)/dbg/trigger-review/test.vvp > $(BUILD)/dbg/trigger-review/run.log 2>&1
	cat $(BUILD)/dbg/trigger-review/run.log
	grep -q 'karudbg trigger review regressions: PASS' $(BUILD)/dbg/trigger-review/run.log

.PHONY: dbg-trigger-invariant-test
dbg-trigger-invariant-test:
	mkdir -p $(BUILD)/dbg/inv40
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_FULL -DKARU_RVA23S64 -s tb_debug_invariants -o $(BUILD)/dbg/inv40/test.vvp test/dbg/tb_debug_invariants.sv rtl/karu_assert.sv
	python3 test/dbg/run_debug_invariants.py --binary $(BUILD)/dbg/inv40/test.vvp --out $(BUILD)/dbg/inv40
