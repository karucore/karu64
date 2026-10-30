# Use the maintained mapper/STA flow for comparable debug-off/on measurements.
DBG_SYN_DEFINES ?= KARU_RVA23S64 KARU_ICACHE KARU_ZVK KARU_KECCAK KARU_M_MUL_CYCLES=4 KARU_M_DIV_CYCLES=64 KARU_V_MUL_CYCLES=16 KARU_V_DIV_CYCLES=64 KARU_V_LANE_PIPE KARU_V_CWB_STAGE KARU_SMCNTRPMF KARU_SSCOFPMF
DBG_SYN_ROOT ?= $(abspath $(BUILD)/syn_out/karudbg)
DBG_TCK_PS ?= 100000
VIVADO ?= vivado

.PHONY: dbg-syn-area-off dbg-syn-area-on dbg-syn-timing-off dbg-syn-timing-on
dbg-syn-area-off:
	KARU_TOP=karu64 KARU_RTL_MANIFEST=$(abspath flow/asic/karu64.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES)' KARU_CLK_PS=5000 KARU_NOSHARE=1 \
	KARU_NO_STA=1 KARU_ABC_FAST=1 KARU_ABC_FULL=0 \
	KARU_OUT_DIR=$(DBG_SYN_ROOT)/area_off flow/syn/syn_yosys.sh
dbg-syn-area-on:
	KARU_TOP=karudbg_top KARU_RTL_MANIFEST=$(abspath dbg/karudbg.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES) KARU_DBG' KARU_CLK_PS=5000 KARU_NOSHARE=1 \
	KARU_NO_STA=1 KARU_ABC_FAST=1 KARU_ABC_FULL=0 \
	KARU_OUT_DIR=$(DBG_SYN_ROOT)/area_on flow/syn/syn_yosys.sh
dbg-syn-timing-off:
	KARU_TOP=karu64 KARU_RTL_MANIFEST=$(abspath flow/asic/karu64.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES)' KARU_CLK_PS=5000 KARU_NOSHARE=1 \
	KARU_NO_STA=0 KARU_ABC_FAST=0 KARU_ABC_FULL=1 KARU_ABC_UPRATE_PS=2000 \
	KARU_OUT_DIR=$(DBG_SYN_ROOT)/timing_off flow/syn/syn_yosys.sh
dbg-syn-timing-on:
	KARU_TOP=karudbg_top KARU_RTL_MANIFEST=$(abspath dbg/karudbg.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES) KARU_DBG' KARU_CLK_PS=5000 KARU_NOSHARE=1 \
	KARU_SDC_TEMPLATE=$(abspath dbg/karudbg.sdc.in) KARU_TCK_PS=$(DBG_TCK_PS) \
	KARU_NO_STA=0 KARU_ABC_FAST=0 KARU_ABC_FULL=1 KARU_ABC_UPRATE_PS=2000 \
	KARU_OUT_DIR=$(DBG_SYN_ROOT)/timing_on flow/syn/syn_yosys.sh

.PHONY: dbg-vivado-ooc
dbg-vivado-ooc:
	@mkdir -p $(BUILD)/dbg/vivado_ooc
	KARU_DBG_OUT=$(abspath $(BUILD)/dbg/vivado_ooc) KARU_DEFINES='$(DBG_SYN_DEFINES) KARU_DBG' \
	$(VIVADO) -mode batch -nojournal -notrace -log $(BUILD)/dbg/vivado_ooc/vivado.log \
	-source dbg/vivado_ooc.tcl

# Each extension is measured against an identical shipping core and mapping.
# Keep the existing base off/on targets for reproducibility of earlier rows.
DBG_SYN_EXTENSION ?= full
DBG_SYN_EXTENSION_DEFINES_base =
DBG_SYN_EXTENSION_DEFINES_autoexec = KARU_DBG_AUTOEXEC
DBG_SYN_EXTENSION_DEFINES_triggers = KARU_DBG_TRIGGERS
DBG_SYN_EXTENSION_DEFINES_sba = KARU_DBG_SBA
DBG_SYN_EXTENSION_DEFINES_full = KARU_DBG_FULL
DBG_SYN_EXTENSION_DEFINES_full4 = KARU_DBG_FULL KARU_DBG_TRIGGER_COUNT=4
DBG_SYN_EXTENSIONS = base autoexec triggers sba full full4
.PHONY: dbg-syn-extension-area dbg-syn-extension-timing dbg-syn-extension-matrix

dbg-syn-extension-area:
	@test -n '$(filter $(DBG_SYN_EXTENSION),$(DBG_SYN_EXTENSIONS))'
	KARU_TOP=karudbg_top KARU_RTL_MANIFEST=$(abspath dbg/karudbg.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES) KARU_DBG $(DBG_SYN_EXTENSION_DEFINES_$(DBG_SYN_EXTENSION))' \
	KARU_CLK_PS=5000 KARU_NOSHARE=1 KARU_NO_STA=1 KARU_ABC_FAST=1 KARU_ABC_FULL=0 \
	KARU_OUT_DIR=$(DBG_SYN_ROOT)/area_$(DBG_SYN_EXTENSION) flow/syn/syn_yosys.sh

dbg-syn-extension-timing:
	@test -n '$(filter $(DBG_SYN_EXTENSION),$(DBG_SYN_EXTENSIONS))'
	KARU_TOP=karudbg_top KARU_RTL_MANIFEST=$(abspath dbg/karudbg.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES) KARU_DBG $(DBG_SYN_EXTENSION_DEFINES_$(DBG_SYN_EXTENSION))' \
	KARU_CLK_PS=5000 KARU_NOSHARE=1 KARU_NO_STA=0 KARU_ABC_FAST=0 KARU_ABC_FULL=1 \
	KARU_ABC_UPRATE_PS=2000 KARU_SDC_TEMPLATE=$(abspath dbg/karudbg.sdc.in) KARU_TCK_PS=$(DBG_TCK_PS) \
	KARU_OUT_DIR=$(DBG_SYN_ROOT)/timing_$(DBG_SYN_EXTENSION) flow/syn/syn_yosys.sh

# Bound concurrent full-core mappings: each row previously peaked near 23 GB.
# Run with -jN deliberately; no unbounded recursive parallelism.
dbg-syn-extension-matrix: $(addprefix dbg-syn-extension-area-,$(DBG_SYN_EXTENSIONS))
.PHONY: $(addprefix dbg-syn-extension-area-,$(DBG_SYN_EXTENSIONS))
$(addprefix dbg-syn-extension-area-,$(DBG_SYN_EXTENSIONS)):
	$(MAKE) DBG_SYN_EXTENSION=$(@:dbg-syn-extension-area-%=%) dbg-syn-extension-area

# Read completed evidence only; no synthesis job is launched by this target.
.PHONY: dbg-measurements-report dbg-measurements-collector-test
dbg-measurements-report:
	python3 dbg/collect_measurements.py --root $(DBG_SYN_ROOT)
dbg-measurements-collector-test:
	python3 test/dbg/test_measurement_collector.py
	python3 -m unittest discover -s test/dbg -p test_source_equivalence.py
	python3 -m unittest discover -s test/dbg -p test_dm_equivalence.py

.PHONY: dbg-runtime-div-audit
dbg-runtime-div-audit:
	KARU_TOP=karudbg_top KARU_RTL_MANIFEST=$(abspath dbg/karudbg.f) \
	KARU_DEFINES='$(DBG_SYN_DEFINES) KARU_DBG KARU_DBG_FULL' KARU_CLK_PS=5000 \
	KARU_DIV_AUDIT_ONLY=1 KARU_OUT_DIR=$(abspath $(BUILD)/dbg/div-audit) \
	flow/syn/syn_yosys.sh
