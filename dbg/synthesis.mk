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
