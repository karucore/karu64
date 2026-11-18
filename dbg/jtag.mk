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

$(BUILD)/dbg/obj_jtag/Vtb_jtag_remote: test/dbg/tb_jtag_remote.v test/dbg/remote_bitbang.cc $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_sba.v dbg/karudbg_rom.v $(wildcard dbg/*.vh)
	mkdir -p $(BUILD)/dbg
	flock $(BUILD)/dbg/jtag-build.lock verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Idbg --top-module tb_jtag_remote --Mdir $(BUILD)/dbg/obj_jtag test/dbg/tb_jtag_remote.v $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_sba.v dbg/karudbg_rom.v $(abspath test/dbg/remote_bitbang.cc) > $(BUILD)/dbg/jtag-build.log 2>&1

DBG_OPENOCD_FLAGS ?= -DKARU_DBG -DKARU_RVA23S64 -DKARU_ZVK -DKARU_KECCAK -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_ICACHE -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_SMCNTRPMF
DBG_OPENOCD_DIR ?= $(BUILD)/dbg/obj_jtag_core
DBG_OPENOCD_MODEL = $(DBG_OPENOCD_DIR)/Vtb_jtag_core
DBG_OPENOCD_FLAG_FILE ?= $(BUILD)/dbg/openocd-flags.txt
DBG_OPENOCD_BUILD_LOG ?= $(BUILD)/dbg/jtag-core-build.log
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
$(DBG_OPENOCD_FLAG_FILE): dbg-openocd-flags-force
	@mkdir -p $(dir $@)
	@printf '%s\n' '$(DBG_OPENOCD_FLAGS)' > $@.tmp
	@if cmp -s $@ $@.tmp; then rm $@.tmp; else mv $@.tmp $@; fi

$(DBG_OPENOCD_MODEL): test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv test/dbg/remote_bitbang.cc dbg/karudbg.f $(filter %.v,$(shell cat dbg/karudbg.f)) $(wildcard rtl/*.vh rtl/*.sv dbg/*.vh) $(DBG_OPENOCD_FLAG_FILE)
	mkdir -p $(BUILD)/dbg
	flock $(BUILD)/dbg/jtag-core-build.lock verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Irtl -Idbg $(DBG_OPENOCD_FLAGS) --top-module tb_jtag_core --Mdir $(DBG_OPENOCD_DIR) -CFLAGS -DKARUDBG_CORE_TARGET test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv -f dbg/karudbg.f $(abspath test/dbg/remote_bitbang.cc) > $(DBG_OPENOCD_BUILD_LOG) 2>&1

# Separate model/flag record keeps the feature-off interoperability row intact.
.PHONY: dbg-autoexec-model dbg-autoexec-core-test dbg-autoexec-gdb-test
dbg-autoexec-model:
	$(MAKE) DBG_OPENOCD_DIR=$(BUILD)/dbg/obj_jtag_core_autoexec \
	  DBG_OPENOCD_FLAG_FILE=$(BUILD)/dbg/obj_jtag_core_autoexec/flags.txt \
	  DBG_OPENOCD_BUILD_LOG=$(BUILD)/dbg/jtag-core-autoexec-build.log \
	  DBG_OPENOCD_FLAGS='$(DBG_OPENOCD_FLAGS) -DKARU_DBG_AUTOEXEC' \
	  $(BUILD)/dbg/obj_jtag_core_autoexec/Vtb_jtag_core

dbg-autoexec-core-test: dbg-autoexec-model
	python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_jtag_core_autoexec/Vtb_jtag_core \
	  --openocd $(OPENOCD) --out $(BUILD)/dbg/openocd-autoexec \
	  --config test/dbg/openocd_core.cfg --marker 'PASS OpenOCD real hart' --timeout 60

dbg-autoexec-gdb-test: dbg-autoexec-model $(BUILD)/dbg/gdb-target.elf
	python3 test/dbg/run_gdb.py --model $(BUILD)/dbg/obj_jtag_core_autoexec/Vtb_jtag_core \
	  --openocd $(OPENOCD) --gdb $(DBG_GDB) \
	  --elf $(BUILD)/dbg/gdb-target.elf --out $(BUILD)/dbg/gdb-autoexec

.PHONY: dbg-sba-model dbg-sba-openocd-test
dbg-sba-model:
	$(MAKE) DBG_OPENOCD_DIR=$(BUILD)/dbg/obj_jtag_core_sba \
	  DBG_OPENOCD_FLAG_FILE=$(BUILD)/dbg/obj_jtag_core_sba/flags.txt \
	  DBG_OPENOCD_BUILD_LOG=$(BUILD)/dbg/jtag-core-sba-build.log \
	  DBG_OPENOCD_FLAGS='$(DBG_OPENOCD_FLAGS) -DKARU_DBG_AUTOEXEC -DKARU_DBG_SBA' \
	  $(BUILD)/dbg/obj_jtag_core_sba/Vtb_jtag_core

dbg-sba-openocd-test: dbg-sba-model
	python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_jtag_core_sba/Vtb_jtag_core \
	  --openocd $(OPENOCD) --out $(BUILD)/dbg/openocd-sba \
	  --config test/dbg/openocd_sba.cfg --marker 'PASS OpenOCD SBA native' --timeout 90

# Combined-feature acceptance shares one full-profile simulator.
.PHONY: dbg-full-model dbg-trigger-openocd-test dbg-trigger-gdb-test dbg-full-openocd-test
dbg-full-model:
	$(MAKE) DBG_OPENOCD_DIR=$(BUILD)/dbg/obj_jtag_core_full \
	  DBG_OPENOCD_FLAG_FILE=$(BUILD)/dbg/obj_jtag_core_full/flags.txt \
	  DBG_OPENOCD_BUILD_LOG=$(BUILD)/dbg/jtag-core-full-build.log \
	  DBG_OPENOCD_FLAGS='$(DBG_OPENOCD_FLAGS) -DKARU_DBG_FULL' \
	  $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core

dbg-trigger-openocd-test: dbg-full-model
	python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core \
	  --openocd $(OPENOCD) --out $(BUILD)/dbg/openocd-triggers \
	  --config test/dbg/openocd_triggers.cfg --marker 'PASS OpenOCD hardware breakpoints' --timeout 90

dbg-trigger-gdb-test: dbg-full-model $(BUILD)/dbg/gdb-target.elf
	python3 test/dbg/run_gdb.py --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core \
	  --openocd $(OPENOCD) --gdb $(DBG_GDB) --triggers \
	  --elf $(BUILD)/dbg/gdb-target.elf --out $(BUILD)/dbg/gdb-triggers

dbg-full-openocd-test: dbg-full-model
	python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core \
	  --openocd $(OPENOCD) --out $(BUILD)/dbg/openocd-full \
	  --config test/dbg/openocd_core.cfg --marker 'PASS OpenOCD real hart' --timeout 90
	python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core \
	  --openocd $(OPENOCD) --out $(BUILD)/dbg/openocd-full-sba \
	  --config test/dbg/openocd_sba.cfg --marker 'PASS OpenOCD SBA native' --timeout 90
