# Optional VCU118 debug integration and bounded USER4 simulation.
# Combined extensions are the FPGA acceptance composition. Set this empty
# explicitly to reproduce the original base-DM configuration.
VCU118_DBG_EXT_DEFINES ?= KARU_DBG_FULL
.PHONY: vcu118-ddr-sgmii-rom-rva23s64-dbg
vcu118-ddr-sgmii-rom-rva23s64-dbg:
	$(MAKE) vcu118-ddr-sgmii-rom-rva23s64 \
	  VCU118_VEC_EXTRA_DEFINES='$(VCU118_VEC_EXTRA_DEFINES) KARU_DBG $(VCU118_DBG_EXT_DEFINES)' \
	  KARU_REPORT_TAG='$(if $(KARU_REPORT_TAG),$(KARU_REPORT_TAG),ddr_rva23s64_dbg_sgmii_75_rom)'

DBG_BSCAN_MODEL = $(BUILD)/dbg/obj_bscan/Vtb_bscan_remote
DBG_BSCAN_CORE_DIR ?= $(BUILD)/dbg/obj_bscan_core
DBG_BSCAN_CORE_MODEL = $(DBG_BSCAN_CORE_DIR)/Vtb_bscan_remote
DBG_BSCAN_CORE_FLAGS ?= $(DBG_OPENOCD_FLAGS)
DBG_BSCAN_CORE_FLAG_FILE ?= $(BUILD)/dbg/bscan-core-flags.txt
DBG_BSCAN_CORE_BUILD_LOG ?= $(BUILD)/dbg/bscan-core-build.log
.PHONY: dbg-bscan-test dbg-bscan-core-test dbg-bscan-protocol-test dbg-bscan-negative-test dbg-reset-test dbg-fpga-reset-test
dbg-bscan-test: $(DBG_BSCAN_MODEL) dbg-bscan-protocol-test dbg-bscan-negative-test dbg-reset-test dbg-fpga-reset-test
	python3 test/dbg/run_openocd_transport.py --model $(DBG_BSCAN_MODEL) --openocd $(OPENOCD) \
	  --out $(BUILD)/dbg/bscan --config test/dbg/openocd_bscan.cfg \
	  --marker 'PASS OpenOCD BSCAN nested TAP'

dbg-reset-test: $(BUILD)/dbg/tb_reset_release.vvp
	vvp $< | tee $(BUILD)/dbg/reset-release.log
	grep -q 'PASS debug reset release' $(BUILD)/dbg/reset-release.log

$(BUILD)/dbg/tb_reset_release.vvp: test/dbg/tb_reset_release.sv dbg/karudbg_reset.v
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -s tb_reset_release -o $@ $^

dbg-fpga-reset-test: $(BUILD)/dbg/tb_fpga_reset.vvp
	vvp $< | tee $(BUILD)/dbg/fpga-reset.log
	grep -q 'PASS FPGA debug reset ordering' $(BUILD)/dbg/fpga-reset.log

$(BUILD)/dbg/tb_fpga_reset.vvp: test/dbg/tb_fpga_reset.sv dbg/karudbg_fpga_reset.v dbg/karudbg_reset.v flow/fpga/reset_ctrl.v
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -s tb_fpga_reset -o $@ $^

dbg-bscan-protocol-test: $(BUILD)/dbg/tb_bscan_protocol.vvp
	vvp $< | tee $(BUILD)/dbg/bscan-protocol.log
	grep -q 'PASS BSCAN protocol' $(BUILD)/dbg/bscan-protocol.log

dbg-bscan-negative-test:
	python3 test/dbg/test_bscan_negative.py --out $(BUILD)/dbg/bscan-negative

$(BUILD)/dbg/tb_bscan_protocol.vvp: test/dbg/tb_bscan_protocol.sv test/dbg/tb_bscan_remote.v test/dbg/xilinx_tap_model.v test/dbg/tb_jtag_remote.v dbg/karudbg_bscan_tunnel.v dbg/karudbg_reset.v $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_sba.v dbg/karudbg_rom.v
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -Idbg -s tb_bscan_protocol -o $@ $^

$(DBG_BSCAN_MODEL): test/dbg/tb_bscan_remote.v test/dbg/xilinx_tap_model.v test/dbg/tb_jtag_remote.v test/dbg/remote_bitbang.cc dbg/karudbg_bscan_tunnel.v dbg/karudbg_reset.v $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_sba.v dbg/karudbg_rom.v $(wildcard dbg/*.vh)
	mkdir -p $(BUILD)/dbg
	verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Idbg \
	  --top-module tb_bscan_remote --Mdir $(BUILD)/dbg/obj_bscan \
	  -CFLAGS -DKARUDBG_BSCAN_TARGET test/dbg/tb_bscan_remote.v \
	  test/dbg/xilinx_tap_model.v test/dbg/tb_jtag_remote.v \
	  dbg/karudbg_bscan_tunnel.v dbg/karudbg_reset.v $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_sba.v \
	  dbg/karudbg_rom.v $(abspath test/dbg/remote_bitbang.cc) \
	  > $(BUILD)/dbg/bscan-build.log 2>&1

dbg-bscan-core-test: $(DBG_BSCAN_CORE_MODEL) $(DBG_OPENOCD_PATCHED)
	KARUDBG_BSCAN=1 python3 test/dbg/run_openocd_transport.py --model $< \
	  --openocd $(DBG_OPENOCD) --out $(BUILD)/dbg/bscan-core \
	  --config test/dbg/openocd_core.cfg --marker 'PASS OpenOCD real hart' --timeout 45

.PHONY: dbg-bscan-gdb-test dbg-bscan-translation-test
dbg-bscan-gdb-test: $(DBG_BSCAN_CORE_MODEL) $(DBG_OPENOCD_PATCHED) $(BUILD)/dbg/gdb-target.elf
	KARUDBG_BSCAN=1 python3 test/dbg/run_gdb.py --model $(DBG_BSCAN_CORE_MODEL) \
	  --openocd $(DBG_OPENOCD) --gdb $(DBG_GDB) --elf $(BUILD)/dbg/gdb-target.elf \
	  --out $(BUILD)/dbg/bscan-gdb

dbg-bscan-translation-test: $(DBG_BSCAN_CORE_MODEL) $(DBG_OPENOCD_PATCHED)
	KARUDBG_BSCAN=1 python3 test/dbg/run_openocd_transport.py --model $< \
	  --openocd $(DBG_OPENOCD) --out $(BUILD)/dbg/bscan-translation \
	  --config test/dbg/openocd_translation.cfg --marker 'PASS OpenOCD translation' --timeout 180

$(DBG_BSCAN_CORE_MODEL): test/dbg/tb_bscan_remote.v test/dbg/xilinx_tap_model.v test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv test/dbg/remote_bitbang.cc dbg/karudbg_bscan_tunnel.v dbg/karudbg_reset.v dbg/karudbg.f $(filter %.v,$(shell cat dbg/karudbg.f)) $(wildcard rtl/*.vh rtl/*.sv dbg/*.vh) $(DBG_BSCAN_CORE_FLAG_FILE)
	mkdir -p $(BUILD)/dbg
	verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Irtl -Idbg \
	  $(DBG_BSCAN_CORE_FLAGS) -DKARUDBG_BSCAN_CORE --top-module tb_bscan_remote \
	  --Mdir $(DBG_BSCAN_CORE_DIR) \
	  -CFLAGS '-DKARUDBG_BSCAN_TARGET -DKARUDBG_CORE_TARGET' \
	  test/dbg/tb_bscan_remote.v test/dbg/xilinx_tap_model.v \
	  test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv \
	  dbg/karudbg_bscan_tunnel.v -f dbg/karudbg.f \
	  $(abspath test/dbg/remote_bitbang.cc) > $(DBG_BSCAN_CORE_BUILD_LOG) 2>&1

.PHONY: dbg-bscan-core-flags-force
$(DBG_BSCAN_CORE_FLAG_FILE): dbg-bscan-core-flags-force
	@mkdir -p $(dir $@)
	@printf '%s\n' '$(DBG_BSCAN_CORE_FLAGS)' > $@.tmp
	@if cmp -s $@ $@.tmp; then rm $@.tmp; else mv $@.tmp $@; fi

# Use a distinct model and flag record for the default full FPGA composition.
.PHONY: dbg-bscan-full-model dbg-bscan-full-test
dbg-bscan-full-model:
	$(MAKE) DBG_JOBS=6 DBG_BSCAN_CORE_DIR=$(BUILD)/dbg/obj_bscan_core_full \
	  DBG_BSCAN_CORE_FLAG_FILE=$(BUILD)/dbg/obj_bscan_core_full/flags.txt \
	  DBG_BSCAN_CORE_BUILD_LOG=$(BUILD)/dbg/bscan-core-full-build.log \
	  DBG_BSCAN_CORE_FLAGS='$(DBG_OPENOCD_FLAGS) -DKARU_DBG_FULL' \
	  $(BUILD)/dbg/obj_bscan_core_full/Vtb_bscan_remote

dbg-bscan-full-test: dbg-bscan-full-model $(BUILD)/dbg/gdb-target.elf
	KARUDBG_BSCAN=1 python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_bscan_core_full/Vtb_bscan_remote --openocd $(OPENOCD) \
	  --out $(BUILD)/dbg/bscan-full-core --config test/dbg/openocd_core.cfg \
	  --marker 'PASS OpenOCD real hart' --timeout 90
	KARUDBG_BSCAN=1 python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_bscan_core_full/Vtb_bscan_remote --openocd $(OPENOCD) \
	  --out $(BUILD)/dbg/bscan-full-triggers --config test/dbg/openocd_triggers.cfg \
	  --marker 'PASS OpenOCD hardware breakpoints' --timeout 90
	KARUDBG_BSCAN=1 python3 test/dbg/run_openocd_transport.py \
	  --model $(BUILD)/dbg/obj_bscan_core_full/Vtb_bscan_remote --openocd $(OPENOCD) \
	  --out $(BUILD)/dbg/bscan-full-sba --config test/dbg/openocd_sba.cfg \
	  --marker 'PASS OpenOCD SBA native' --timeout 90
	KARUDBG_BSCAN=1 python3 test/dbg/run_gdb.py \
	  --model $(BUILD)/dbg/obj_bscan_core_full/Vtb_bscan_remote --openocd $(OPENOCD) \
	  --gdb $(DBG_GDB) --triggers --timeout 120 --client-timeout 45 \
	  --elf $(BUILD)/dbg/gdb-target.elf --out $(BUILD)/dbg/bscan-full-gdb
