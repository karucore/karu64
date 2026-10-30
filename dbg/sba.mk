# Standalone core/SBA bus arbitration and coherent-write protocol tests.
.PHONY: dbg-sba-bus-test
dbg-sba-bus-test: $(BUILD)/dbg/tb_sba_bus.vvp $(BUILD)/dbg/tb_sba_bus_secure.vvp $(BUILD)/dbg/tb_sba_bus_locked.vvp
	vvp $< | tee $(BUILD)/dbg/sba-bus.log
	grep -q 'karudbg SBA bus: PASS' $(BUILD)/dbg/sba-bus.log
	vvp $(BUILD)/dbg/tb_sba_bus_secure.vvp | tee $(BUILD)/dbg/sba-bus-secure.log
	grep -q 'karudbg SBA bus: PASS' $(BUILD)/dbg/sba-bus-secure.log
	vvp $(BUILD)/dbg/tb_sba_bus_locked.vvp | tee $(BUILD)/dbg/sba-bus-locked.log
	grep -q 'karudbg SBA bus locked: PASS' $(BUILD)/dbg/sba-bus-locked.log
$(BUILD)/dbg/tb_sba_bus.vvp: test/dbg/tb_sba_bus.sv dbg/karudbg_bus.v rtl/karu_pma.vh dbg/karudbg_defs.vh
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -s tb_sba_bus -o $@ test/dbg/tb_sba_bus.sv dbg/karudbg_bus.v

$(BUILD)/dbg/tb_sba_bus_secure.vvp: test/dbg/tb_sba_bus.sv dbg/karudbg_bus.v rtl/karu_pma.vh dbg/karudbg_defs.vh
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DTEST_SBA_SECURE -s tb_sba_bus -o $@ test/dbg/tb_sba_bus.sv dbg/karudbg_bus.v
$(BUILD)/dbg/tb_sba_bus_locked.vvp: test/dbg/tb_sba_bus.sv dbg/karudbg_bus.v rtl/karu_pma.vh dbg/karudbg_defs.vh
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DTEST_SBA_LOCKED -s tb_sba_bus -o $@ test/dbg/tb_sba_bus.sv dbg/karudbg_bus.v

.PHONY: dbg-sba-core-negative-test
dbg-sba-core-negative-test:
	python3 test/dbg/test_core_negative.py --sba --build-dir $(BUILD)/dbg/sba-core-negative --jobs 2

.PHONY: dbg-sba-invariant-test dbg-sba-core-locked-test dbg-sba-core-four-state-test
dbg-sba-invariant-test:
	python3 test/dbg/test_sba_invariants.py

dbg-sba-core-locked-test:
	mkdir -p $(BUILD)/dbg/core-sba-locked
	timeout 120 iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_SBA -DKARU_NO_F -DKARU_ASIC -DTEST_SBA_PROBE -DTEST_SBA_CORE_LOCKED \
	  -s tb_dbg_core -o $(BUILD)/dbg/core-sba-locked/test.vvp test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)
	timeout 120 vvp $(BUILD)/dbg/core-sba-locked/test.vvp > $(BUILD)/dbg/core-sba-locked/run.log 2>&1
	cat $(BUILD)/dbg/core-sba-locked/run.log
	grep -q 'karudbg locked core SBA: PASS' $(BUILD)/dbg/core-sba-locked/run.log

dbg-sba-core-four-state-test:
	mkdir -p $(BUILD)/dbg/core-sba-four-state
	timeout 120 iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_SBA -DKARU_ICACHE -DKARU_NO_F -DKARU_ASIC -DTEST_SBA_PROBE \
	  -s tb_dbg_core -o $(BUILD)/dbg/core-sba-four-state/test.vvp test/dbg/tb_dbg_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)
	timeout 120 vvp $(BUILD)/dbg/core-sba-four-state/test.vvp > $(BUILD)/dbg/core-sba-four-state/run.log 2>&1
	cat $(BUILD)/dbg/core-sba-four-state/run.log
	grep -q 'karudbg focused SBA probe: PASS' $(BUILD)/dbg/core-sba-four-state/run.log

.PHONY: dbg-sba-review-negative-test
dbg-sba-review-negative-test:
	python3 test/dbg/test_sba_review.py
