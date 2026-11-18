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

# SBA/core/imem co-simulation through the real VCU118 crossbar (finding S13):
# karudbg_bus + karu_ddr_xbar with SIM_TB assertions + karu_axi4_ram + real
# peripherals, byte-level scoreboard. Positive runs use the narrow/misaligned
# SBA mix; two patched copies of karudbg_bus.v must be detected.
SBA_XBAR_DIR    = $(BUILD)/dbg/sba-xbar
SBA_XBAR_JOBS  ?= 4
SBA_XBAR_SEEDS  = 1 2
SBA_XBAR_CYCLES = 100000
SBA_XBAR_RTL    = flow/fpga/karu_ddr_xbar.v flow/fpga/assert/karu_ddr_xbar_assert.v flow/fpga/karu_axi4_ram.v \
	flow/fpga/karu_boot_mem.v flow/fpga/karu_qspi_mmio.v flow/fpga/karu_ns16550.v \
	rtl/karu_clint.v rtl/karu_plic.v flow/fpga/eth/karu_eth.v flow/fpga/eth/liteeth_core.v \
	flow/fpga/eth/eth_mii_loopback.v flow/fpga/eth/eth_sim_prims.v flow/fpga/uart_tx.v flow/fpga/uart_rx.v
SBA_XBAR_VFLAGS = --binary --timing -j $(SBA_XBAR_JOBS) -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
	-Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-INITIALDLY -Wno-TIMESCALEMOD -Wno-UNOPTFLAT -Wno-CMPCONST -Wno-COMBDLY \
	-DSIM_TB -DKARU_DBG -DKARU_DBG_SBA -Irtl -Idbg -Iflow/fpga --top-module tb_sba_xbar
SBA_XBAR_PASS   = PASS SBA crossbar co-simulation
SBA_XBAR_MUTANTS = raw_ram_beat req_ready_ignores_core

# $(1)=bench name, $(2)=karudbg_bus.v source
define sba_xbar_build
	timeout 600 verilator $(SBA_XBAR_VFLAGS) -Mdir $(SBA_XBAR_DIR)/obj-$(1) test/dbg/tb_sba_xbar.sv $(2) $(SBA_XBAR_RTL) \
	  > $(SBA_XBAR_DIR)/build-$(1).log 2>&1 || { tail -30 $(SBA_XBAR_DIR)/build-$(1).log; echo "BUILD FAILED: $(1)"; exit 1; }
endef
# $(1)=log name, $(2)=bench name, $(3)=plusargs
define sba_xbar_run
	(cd $(SBA_XBAR_DIR) && exec timeout 120 ./obj-$(2)/Vtb_sba_xbar $(3)) > $(SBA_XBAR_DIR)/$(1).log 2>&1; rc=$$?; \
	  grep -m1 '^DONE' $(SBA_XBAR_DIR)/$(1).log || true; \
	  if [ $$rc -ne 0 ] || ! grep -qx '$(SBA_XBAR_PASS)' $(SBA_XBAR_DIR)/$(1).log; then \
	    tail -20 $(SBA_XBAR_DIR)/$(1).log; echo "FAIL $(1) (rc=$$rc)"; exit 1; fi; echo "ok $(1)"
endef
# $(1)=mutant name, $(2)=plusargs, $(3)=ERE that must appear in the log,
# $(4)=optional ERE that must not appear (detector that has to stay out of it)
define sba_xbar_neg
	(cd $(SBA_XBAR_DIR) && exec timeout 120 ./obj-mut-$(1)/Vtb_sba_xbar $(2)) > $(SBA_XBAR_DIR)/mut-$(1).log 2>&1; \
	  if grep -q '$(SBA_XBAR_PASS)' $(SBA_XBAR_DIR)/mut-$(1).log; then echo "UNDETECTED mutant $(1)"; exit 1; fi; \
	  if [ -n '$(4)' ] && grep -Eq '$(4)' $(SBA_XBAR_DIR)/mut-$(1).log; then \
	    tail -20 $(SBA_XBAR_DIR)/mut-$(1).log; echo "mutant $(1): detected by excluded check /$(4)/"; exit 1; fi; \
	  if ! grep -Eq '$(3)' $(SBA_XBAR_DIR)/mut-$(1).log; then \
	    tail -20 $(SBA_XBAR_DIR)/mut-$(1).log; echo "mutant $(1): expected failure text /$(3)/ not found"; exit 1; fi; \
	  echo "detected mutant $(1): $$(grep -Em1 '$(3)' $(SBA_XBAR_DIR)/mut-$(1).log)"
endef

.PHONY: dbg-sba-xbar-test
dbg-sba-xbar-test:
	mkdir -p $(SBA_XBAR_DIR)
	printf '%016x\n' 0 1 2 3 4 5 6 7 > $(SBA_XBAR_DIR)/rom.hex
	for m in $(SBA_XBAR_MUTANTS); do \
	  rm -rf $(SBA_XBAR_DIR)/mut-$$m && mkdir -p $(SBA_XBAR_DIR)/mut-$$m && \
	  patch -s --fuzz=0 -r $(SBA_XBAR_DIR)/mut-$$m/rej -o $(SBA_XBAR_DIR)/mut-$$m/karudbg_bus.v dbg/karudbg_bus.v \
	    < test/dbg/sba_xbar_mut_$$m.patch || { echo "mutant $$m no longer applies to dbg/karudbg_bus.v"; exit 1; }; \
	  ! cmp -s dbg/karudbg_bus.v $(SBA_XBAR_DIR)/mut-$$m/karudbg_bus.v || { echo "mutant $$m is a no-op"; exit 1; }; \
	done
	$(call sba_xbar_build,good,dbg/karudbg_bus.v)
	$(call sba_xbar_build,mut-raw_ram_beat,$(SBA_XBAR_DIR)/mut-raw_ram_beat/karudbg_bus.v)
	$(call sba_xbar_build,mut-req_ready_ignores_core,$(SBA_XBAR_DIR)/mut-req_ready_ignores_core/karudbg_bus.v)
	for s in $(SBA_XBAR_SEEDS); do $(call sba_xbar_run,narrow_s$$s,good,+seed=$$s +cycles=$(SBA_XBAR_CYCLES)) || exit 1; done
	$(call sba_xbar_run,no_sba,good,+seed=1 +cycles=50000 +sba_rate=0)
	$(call sba_xbar_neg,raw_ram_beat,+seed=1 +cycles=$(SBA_XBAR_CYCLES),\[XBAR-ASSERT\] FAIL .*: X(38|39|44|45)[^0-9]|^FAIL t=,SBAB[0-9])
	$(call sba_xbar_neg,req_ready_ignores_core,+seed=1 +cycles=$(SBA_XBAR_CYCLES),SBAB2 SBA ownership differs)
	@echo "dbg-sba-xbar-test: PASS (logs in $(SBA_XBAR_DIR))"
