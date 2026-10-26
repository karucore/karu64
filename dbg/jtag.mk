# karudbg TAP/DTM/CDC tests. Included by the repository Makefile.
KARUDBG_JTAG_SRCS = dbg/karudbg_jtag.v dbg/karudbg_jtag_tap.v dbg/karudbg_cdc.v

.PHONY: dbg-dtm-test
dbg-dtm-test: $(BUILD)/dbg/tb_dtm.vvp
	vvp $<

$(BUILD)/dbg/tb_dtm.vvp: test/dbg/tb_dtm.sv $(KARUDBG_JTAG_SRCS)
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Wall -s tb_dtm -o $@ $^

.PHONY: dbg-transport-negative-test
dbg-transport-negative-test:
	python3 test/dbg/negative_transport.py --out $(BUILD)/dbg/negative

.PHONY: dbg-axi-test
dbg-axi-test: $(BUILD)/dbg/tb_dbg_axi.vvp
	vvp $<

$(BUILD)/dbg/tb_dbg_axi.vvp: test/dbg/tb_dbg_axi.sv dbg/karudbg_axi.v
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Wall -s tb_dbg_axi -o $@ $^

OPENOCD ?= openocd
DBG_JOBS ?= 8
.PHONY: dbg-openocd-transport-test
dbg-openocd-transport-test: $(BUILD)/dbg/obj_jtag/Vtb_jtag_remote
	python3 test/dbg/run_openocd_transport.py --model $< --openocd $(OPENOCD) --out $(BUILD)/dbg

$(BUILD)/dbg/obj_jtag/Vtb_jtag_remote: test/dbg/tb_jtag_remote.v test/dbg/remote_bitbang.cc $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_rom.v dbg/karudbg_defs.vh
	mkdir -p $(BUILD)/dbg
	flock $(BUILD)/dbg/jtag-build.lock verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Idbg --top-module tb_jtag_remote --Mdir $(BUILD)/dbg/obj_jtag test/dbg/tb_jtag_remote.v $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_rom.v $(abspath test/dbg/remote_bitbang.cc) > $(BUILD)/dbg/jtag-build.log 2>&1

DBG_OPENOCD_FLAGS ?= -DKARU_DBG -DKARU_RVA23S64 -DKARU_ZVK -DKARU_KECCAK -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_ICACHE -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_SMCNTRPMF
DBG_OPENOCD_MODEL = $(BUILD)/dbg/obj_jtag_core/Vtb_jtag_core
DBG_OPENOCD_PATCHED = $(BUILD)/dbg/openocd/install/bin/openocd
DBG_OPENOCD ?= $(DBG_OPENOCD_PATCHED)
.PHONY: dbg-openocd-build
dbg-openocd-build: $(DBG_OPENOCD_PATCHED)

$(DBG_OPENOCD_PATCHED): dbg/build_openocd.sh dbg/openocd-no-autoexec.patch
	DBG_JOBS=$(DBG_JOBS) sh dbg/build_openocd.sh $(BUILD)/dbg/openocd
.PHONY: dbg-openocd-core-test
dbg-openocd-core-test: $(DBG_OPENOCD_MODEL) $(DBG_OPENOCD_PATCHED)
	python3 test/dbg/run_openocd_transport.py --model $< --openocd $(DBG_OPENOCD) --out $(BUILD)/dbg/openocd-core --config test/dbg/openocd_core.cfg --marker 'PASS OpenOCD real hart'

.PHONY: dbg-translation-test
dbg-translation-test: $(DBG_OPENOCD_MODEL) $(DBG_OPENOCD_PATCHED)
	python3 test/dbg/run_openocd_transport.py --model $< --openocd $(DBG_OPENOCD) --out $(BUILD)/dbg/openocd-translation --config test/dbg/openocd_translation.cfg --marker 'PASS OpenOCD translation' --timeout 90

.PHONY: dbg-openocd-negative-test
dbg-openocd-negative-test: $(DBG_OPENOCD_MODEL)
	python3 test/dbg/run_openocd_transport.py --model $< --openocd $(OPENOCD) --out $(BUILD)/dbg/openocd-pristine-negative --config test/dbg/openocd_pristine_negative.cfg --expect-failure 'unsupported autoexec block mismatch'

.PHONY: dbg-openocd-flags-force
$(BUILD)/dbg/openocd-flags.txt: dbg-openocd-flags-force
	@mkdir -p $(BUILD)/dbg
	@printf '%s\n' '$(DBG_OPENOCD_FLAGS)' > $@.tmp
	@if cmp -s $@ $@.tmp; then rm $@.tmp; else mv $@.tmp $@; fi

$(DBG_OPENOCD_MODEL): test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv test/dbg/remote_bitbang.cc $(filter %.v,$(shell cat dbg/karudbg.f)) $(wildcard rtl/*.vh) dbg/karudbg_defs.vh $(BUILD)/dbg/openocd-flags.txt
	mkdir -p $(BUILD)/dbg
	flock $(BUILD)/dbg/jtag-core-build.lock verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Irtl -Idbg $(DBG_OPENOCD_FLAGS) --top-module tb_jtag_core --Mdir $(BUILD)/dbg/obj_jtag_core -CFLAGS -DKARUDBG_CORE_TARGET test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv -f dbg/karudbg.f $(abspath test/dbg/remote_bitbang.cc) > $(BUILD)/dbg/jtag-core-build.log 2>&1
