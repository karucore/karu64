# Tests of the ring-oscillator noise source's period counters and of the
# phase meter (flow/fpga/karu_rosc_rng.v, flow/fpga/karu_rosc_meter.v).
# Included by the repository Makefile. SPDX-License-Identifier: BSD-2-Clause
#
#   rosc-meter-test   lint of both files; the noise source elaborated as it
#                     is synthesised (Yosys: six rings with their attributes,
#                     six counters, their dividers' look-up tables); the
#                     meter on the behavioural model of the source at 0 to
#                     1, 9, 20 and 40 ring periods per clock, with and
#                     without jitter and shared frequency modulation, a
#                     million clocks in each counting mode at 9, 20 and 40
#                     (test/tb_rosc_meter.sv, tb_rosc_meter); the Verilog
#                     model against its Python copy, symbols, reference bits
#                     and counts in both counting modes, bit for bit; one
#                     counter's divider with the routes to its tables, where
#                     it is right and where it fails (tb_rosc_cnt with
#                     KARU_ROSC_DIV); the counters and the sampled bits as
#                     synthesised, on rings and routing delays made by the
#                     bench, over ROSC_CNT_SAMPLES clock edges in each of
#                     five runs (tb_rosc_cnt); and one-mechanism mutants of
#                     both files (test/rosc_meter_mutants.py). About six
#                     minutes.
#
#   ROSC_RNG          the noise source under test
#   ROSC_MODEL        the Python copy of its behavioural model
ROSC_RNG         ?= flow/fpga/karu_rosc_rng.v
ROSC_MODEL       ?= test/dbg/board/noise_model.py
ROSC_METER        = flow/fpga/karu_rosc_meter.v
ROSC_DIR          = $(BUILD)/rosc-meter
ROSC_CNT_SAMPLES ?= 200000
ROSC_CNT_SETS    ?= 0 1 2 3 4
ROSC_DIV_POINTS  ?= 3000
ROSC_DIV_SETS    ?= 0 1 2
ROSC_SOAK        ?= 1000000

# What the netlist must have after elaboration with SIM = 0: the six ring
# nets with the attributes that keep them in Vivado, the two flops per ring,
# the sampling flops of all six rings, and in every counter the three
# look-up tables of the divider as primitives with DONT_TOUCH, their INIT
# values, the two latch nets as declared loops, and the flops with their
# attributes: SHREG_EXTRACT = "no" on the ring-domain flops and neither
# DONT_TOUCH nor KEEP on any net of a counter, because either makes Vivado
# put a look-up table behind every such flop (flow/fpga/karu_rosc_rng.v).
# Yosys itself does not honour DONT_TOUCH and folds a ring's inverters: only
# Vivado's netlist shows the stages (flow/fpga/rosc_constraints.tcl counts
# them). The script goes to the shell in double quotes.
ROSC_YOSYS = read_verilog -sv $(ROSC_RNG); read_verilog -lib +/xilinx/cells_sim.v; hierarchy -top karu_rosc_rng; proc; opt_clean; \
	select -assert-count 6 karu_rosc_rng/w:*inv a:DONT_TOUCH %i; \
	select -assert-count 6 karu_rosc_rng/w:*inv a:ALLOW_COMBINATORIAL_LOOPS %i; \
	select -assert-count 2 karu_rosc_rng/w:*_q a:DONT_TOUCH %i; \
	select -assert-count 2 karu_rosc_rng/w:*_q a:ASYNC_REG %i; \
	select -assert-count 6 karu_rosc_rng/t:karu_rosc_cnt; \
	select -assert-count 3 karu_rosc_cnt/t:LUT3; \
	select -assert-count 3 karu_rosc_cnt/t:LUT3 a:DONT_TOUCH %i; \
	select -assert-count 1 karu_rosc_cnt/c:div_m r:INIT=8'h8d %i; \
	select -assert-count 1 karu_rosc_cnt/c:div_s r:INIT=8'he4 %i; \
	select -assert-count 1 karu_rosc_cnt/c:div_x r:INIT=8'hac %i; \
	select -assert-count 2 karu_rosc_cnt/w:div_* a:ALLOW_COMBINATORIAL_LOOPS %i; \
	select -assert-count 3 karu_rosc_cnt/w:*_q a:SHREG_EXTRACT=no %i; \
	select -assert-none karu_rosc_cnt/w:* a:DONT_TOUCH %i; \
	select -assert-none karu_rosc_cnt/w:* a:KEEP %i; \
	select -assert-none karu_rosc_cnt/w:* a:keep %i; \
	select -assert-count 2 karu_rosc_cnt/w:*_q a:ASYNC_REG %i; \
	select -assert-count 3 karu_rosc_cnt/t:\$$adff; stat

# $(call rosc_run,<name>,<plusargs>): the meter bench once
rosc_run = $(ROSC_DIR)/obj/tb $(2) > $(ROSC_DIR)/run-$(1).log 2>&1 || { tail -5 $(ROSC_DIR)/run-$(1).log; exit 1; }; grep 'rosc meter test: PASS' $(ROSC_DIR)/run-$(1).log
# $(call rosc_compare,<name>,<model options>): the two dumps of that run against the Python model: the first
# with all rings and counts of two periods, the second with two rings off and counts of one period
rosc_compare = python3 $(ROSC_MODEL) --compare $(ROSC_DIR)/$(1).a.txt $(2) && python3 $(ROSC_MODEL) --compare $(ROSC_DIR)/$(1).b.txt $(2) --ring-en 2b --direct --min-clocks 19000
# $(call rosc_cnt,<directory of the binary>,<sets>,<plusargs>,<log name>,<pass line>): the counter bench, one process per set
rosc_cnt = for s in $(2); do $(ROSC_DIR)/$(1)/tb +set=$$s $(3) > $(ROSC_DIR)/$(4)-$$s.log 2>&1 & done; wait; \
	for s in $(2); do grep '$(5)' $(ROSC_DIR)/$(4)-$$s.log || { tail -8 $(ROSC_DIR)/$(4)-$$s.log; exit 1; }; done

.PHONY: rosc-meter-test
rosc-meter-test: | $(BUILD)
	mkdir -p $(ROSC_DIR)
	{ verilator --lint-only -GSIM=1 --top-module karu_rosc_rng $(ROSC_RNG) \
		&& verilator --lint-only -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -DKARU_ROSC_LINT --top-module karu_rosc_rng $(ROSC_RNG) test/tb_rosc_meter.sv \
		&& verilator --lint-only --top-module karu_rosc_meter $(ROSC_METER); } > $(ROSC_DIR)/lint.log 2>&1 || { cat $(ROSC_DIR)/lint.log; exit 1; }
	yosys -q -l $(ROSC_DIR)/yosys.log -p "$(ROSC_YOSYS)" > /dev/null 2>&1 || { tail -5 $(ROSC_DIR)/yosys.log; exit 1; }
	verilator --binary --timing -Wno-fatal --top-module tb_rosc_meter -Mdir $(ROSC_DIR)/obj -o tb \
		test/tb_rosc_meter.sv $(ROSC_RNG) $(ROSC_METER) > $(ROSC_DIR)/build.log 2>&1 || { tail -20 $(ROSC_DIR)/build.log; exit 1; }
	$(call rosc_run,default,+healthy)
	$(call rosc_run,turns9,+rosc_turns=9 +healthy +soak=$(ROSC_SOAK))
	$(call rosc_run,turns20,+rosc_turns=20 +healthy +soak=$(ROSC_SOAK) +dump=$(ROSC_DIR)/turns20)
	$(call rosc_run,turns40,+rosc_turns=40 +healthy +soak=$(ROSC_SOAK))
	$(call rosc_run,jitter,+rosc_jitter=10 +healthy +dump=$(ROSC_DIR)/jitter)
	$(call rosc_run,shared20,+rosc_jitter=10 +rosc_shared=7 +rosc_turns=20 +healthy +dump=$(ROSC_DIR)/shared20)
	$(call rosc_run,shared40,+rosc_jitter=12 +rosc_shared=10 +rosc_turns=40 +dump=$(ROSC_DIR)/shared40)
	grep -h '^soak' $(ROSC_DIR)/run-turns9.log $(ROSC_DIR)/run-turns20.log $(ROSC_DIR)/run-turns40.log
	$(call rosc_compare,turns20,--turns 20)
	$(call rosc_compare,jitter,--jitter 10)
	$(call rosc_compare,shared20,--jitter 10 --shared 7 --turns 20)
	$(call rosc_compare,shared40,--jitter 12 --shared 10 --turns 40)
	verilator --binary --timing -Wno-fatal -DKARU_ROSC_BENCH -DKARU_ROSC_DIV --top-module tb_rosc_cnt -Mdir $(ROSC_DIR)/objd -o tb \
		test/tb_rosc_meter.sv $(ROSC_RNG) > $(ROSC_DIR)/build-div.log 2>&1 || { tail -20 $(ROSC_DIR)/build-div.log; exit 1; }
	$(call rosc_cnt,objd,$(ROSC_DIV_SETS),+points=$(ROSC_DIV_POINTS),div,rosc divider test: PASS)
	grep -h '^divider sweep' $(ROSC_DIR)/div-*.log
	verilator --binary --timing -Wno-fatal -DKARU_ROSC_BENCH --top-module tb_rosc_cnt -Mdir $(ROSC_DIR)/objc -o tb \
		test/tb_rosc_meter.sv $(ROSC_RNG) > $(ROSC_DIR)/build-cnt.log 2>&1 || { tail -20 $(ROSC_DIR)/build-cnt.log; exit 1; }
	$(call rosc_cnt,objc,$(ROSC_CNT_SETS),+samples=$(ROSC_CNT_SAMPLES),cnt,rosc counter test: PASS)
	python3 test/rosc_meter_mutants.py --out $(ROSC_DIR)/mut --rosc $(ROSC_RNG) > $(ROSC_DIR)/mutants.log 2>&1 || { cat $(ROSC_DIR)/mutants.log; exit 1; }
	tail -1 $(ROSC_DIR)/mutants.log
