# Optional VCU118 debug integration and bounded USER4 simulation.
# Combined extensions are the FPGA acceptance composition:
#   KARU_DBG_FULL   autoexec, triggers, System Bus Access
#   KARU_DBG_AUTH   debug authentication; the lifecycle is on DIP switches
#                   1 and 2, and both off (OPEN) behaves as an image without it
#   KARU_ZKR        the seed CSR and the ring-oscillator entropy source;
#                   DIP switch 4 holds the source off
# Set this to KARU_DBG_FULL for the image without authentication and Zkr, or
# empty for the original base-DM configuration.
VCU118_DBG_EXT_DEFINES ?= KARU_DBG_FULL KARU_DBG_AUTH KARU_ZKR

# The authentication island ROM of the FPGA image: the window routine of
# test/dbg/auth_rom with the contract's 2^30-cycle window, handing over to
# the boot ROM at 0x1000. It still verifies with the simulation-only TEST
# algorithm: the production verifier awaits decision D3, and this image is
# functional validation only.
#
# Where the nonce comes from follows the image. With KARU_ZKR the ROM reads
# seed and waits long enough for the entropy source's start-up test (about
# 4.3 million clocks). Without it there is no seed CSR, and reading it would
# trap with no trap vector set: the ROM then reads mdbgrng, whose port the
# board top ties to DEAD, so a request is refused and the boot goes on.
VCU118_AUTH_ROM_RNG = $(if $(filter KARU_ZKR,$(VCU118_DBG_EXT_DEFINES)),-DCSR_RNG=0x015 -DTRNG_TRIES=200000,)
VCU118_AUTH_ROM_FLAGS ?= $(VCU118_AUTH_ROM_RNG) -DWINDOW_CYCLES=1073741824ull \
	-DAUTH_ROM_NEXT=0x1000 -DAUTH_ROM_NO_MTVEC
VCU118_AUTH_ROM_HEX = $(BUILD)/vcu118_auth_rom.hex
# The flags are kept beside the ROM, so that a build with other flags, or
# with another set of image defines, rebuilds it.
VCU118_AUTH_ROM_STAMP = $(BUILD)/vcu118_auth_rom.flags
.PHONY: vcu118-auth-rom-hex FORCE_AUTH_ROM_FLAGS
vcu118-auth-rom-hex: $(VCU118_AUTH_ROM_HEX)
FORCE_AUTH_ROM_FLAGS:
$(VCU118_AUTH_ROM_STAMP): FORCE_AUTH_ROM_FLAGS | $(BUILD)
	@printf '%s\n' '$(strip $(VCU118_AUTH_ROM_FLAGS))' | cmp -s - $@ || printf '%s\n' '$(strip $(VCU118_AUTH_ROM_FLAGS))' > $@
$(VCU118_AUTH_ROM_HEX): $(DBG_AUTH_ROM_SRCS) dbg/fpga.mk $(VCU118_AUTH_ROM_STAMP) | $(BUILD)
	$(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) $(VCU118_AUTH_ROM_FLAGS) -T test/dbg/auth_rom/rom.ld \
	  -o $(BUILD)/vcu118_auth_rom.elf test/dbg/auth_rom/start.S test/dbg/auth_rom/window.c
	$(XCHAIN)objcopy -O binary -j .text $(BUILD)/vcu118_auth_rom.elf $(BUILD)/vcu118_auth_rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(BUILD)/vcu118_auth_rom.bin > $@
	$(XCHAIN)size $(BUILD)/vcu118_auth_rom.elf

.PHONY: vcu118-ddr-sgmii-rom-rva23s64-dbg
# The device tree must say what the image has: "zkr" exactly when KARU_ZKR is
# built in. rva23-boot-inputs-check enforces it.
VCU118_DBG_DTB_VARIANT ?= $(if $(filter KARU_ZKR,$(VCU118_DBG_EXT_DEFINES)),rva23s64-zkr-ddr,rva23s64-ddr)
vcu118-ddr-sgmii-rom-rva23s64-dbg: $(VCU118_AUTH_ROM_HEX)
	$(MAKE) vcu118-ddr-sgmii-rom-rva23s64 \
	  VCU118_VEC_EXTRA_DEFINES='$(VCU118_VEC_EXTRA_DEFINES) KARU_DBG $(VCU118_DBG_EXT_DEFINES)' \
	  FUBOOT_RVA23_DTB='$(KARUDEB)/build/karu64/karu64-$(VCU118_DBG_DTB_VARIANT).dtb' \
	  VCU118_NETBOOT_FILE_RVA23='$(KARUDEB)/build/karu64/tftp/$(VCU118_DBG_DTB_VARIANT)/uboot-netboot-one-line.txt' \
	  KARU_REPORT_TAG='$(if $(KARU_REPORT_TAG),$(KARU_REPORT_TAG),ddr_rva23s64_dbg_sgmii_75_rom)'

# ---- The debug image's composition in simulation ----
# The SoC as the board has it, without the JTAG transport and the DDR
# controller: karudbg_core with authentication, the entropy source with its
# behavioural noise model, the 2 MiB boot ROM built from the image's own
# fu-boot sources and layout, karudeb's OpenSBI and Zkr device tree, and an
# S-mode payload in U-Boot's place. The hart starts in the authentication
# island ROM of the image, which hands over to fu-boot.
#
# The payload reads seed as Linux does and then reboots through SBI system
# reset, so one run boots twice. Four runs, in parallel:
#   open       lifecycle OPEN: both boots read four seed words
#   auth       lifecycle AUTH, no debugger: the same
#   seed-off   entropy strap low: seed stays in BIST and the boot goes on
#   no-zkr     control: with the tree without zkr OpenSBI leaves SSEED clear,
#              and the seed read traps
# About fifteen minutes; not part of make dbg-test.
IMAGE_BOOT_DIR = $(BUILD)/image-boot
IMAGE_BOOT_SIM = $(IMAGE_BOOT_DIR)/obj/Vfpga_ddr_tb
IMAGE_BOOT_DBG_RTL = dbg/karudbg_auth.v dbg/karudbg_island.v dbg/karudbg_bus.v dbg/karudbg_sba.v \
	dbg/karudbg_core.v dbg/karudbg_axi.v dbg/karudbg.v dbg/karudbg_rom.v
IMAGE_BOOT_ZKR_DTB ?= $(KARUDEB)/build/karu64/karu64-rva23s64-zkr-ddr.dtb
IMAGE_BOOT_PLAIN_DTB ?= $(KARUDEB)/build/karu64/karu64-rva23s64-ddr.dtb
IMAGE_BOOT_BOOT_SRCS = $(VCU118_FUBOOT_SRCS) flow/boot/fugzip.h flow/boot/vcu118_fuboot.ld
IMAGE_BOOT_RUN = +hex=$(IMAGE_BOOT_DIR)/empty.hex +tohost=300000 +max_cycles=80000000
IMAGE_BOOT_PAYLOAD_CC = $(XCHAIN)gcc -march=rv64gc -mabi=lp64d -nostdlib -static -Wl,-Ttext=0x80200000,--no-relax
$(IMAGE_BOOT_DIR)/payload-seed.bin: test/fw/sbi_reboot_payload.S
	mkdir -p $(IMAGE_BOOT_DIR)
	$(IMAGE_BOOT_PAYLOAD_CC) -DSBI_PAYLOAD_SEED -o $(IMAGE_BOOT_DIR)/payload-seed.elf $<
	$(XCHAIN)objcopy -O binary $(IMAGE_BOOT_DIR)/payload-seed.elf $@
$(IMAGE_BOOT_DIR)/payload-off.bin: test/fw/sbi_reboot_payload.S
	mkdir -p $(IMAGE_BOOT_DIR)
	$(IMAGE_BOOT_PAYLOAD_CC) -DSBI_PAYLOAD_SEED -DSBI_PAYLOAD_SEED_OFF -o $(IMAGE_BOOT_DIR)/payload-off.elf $<
	$(XCHAIN)objcopy -O binary $(IMAGE_BOOT_DIR)/payload-off.elf $@
# $(1) image name, $(2) device tree, $(3) payload
define IMAGE_BOOT_ROM
$$(IMAGE_BOOT_DIR)/$(1).rom.hex: $(2) $$(IMAGE_BOOT_DIR)/$(3).bin $$(KARUDEB_OPENSBI) $$(IMAGE_BOOT_BOOT_SRCS) flow/build_fuboot_rom.sh
	mkdir -p $$(IMAGE_BOOT_DIR)/boot-$(1)
	cp $$(IMAGE_BOOT_BOOT_SRCS) $$(IMAGE_BOOT_DIR)/boot-$(1)/
	{ printf '#define FUBOOT_OPENSBI_OFF  %sUL\n' $$(FUBOOT_OPENSBI_OFF); \
	  printf '#define FUBOOT_OPENSBI_SIZE %sUL\n' $$$$(stat -c%s $$(KARUDEB_OPENSBI)); \
	  printf '#define FUBOOT_UBOOT_OFF    %sUL\n' $$(FUBOOT_UBOOT_OFF); \
	  printf '#define FUBOOT_UBOOT_SIZE   %sUL\n' $$$$(stat -c%s $$(IMAGE_BOOT_DIR)/$(3).bin); \
	  printf '#define FUBOOT_DTB_OFF      %sUL\n' $$(FUBOOT_DTB_OFF); \
	  printf '#define FUBOOT_DTB_SIZE     %sUL\n' $$$$(stat -c%s $(2)); } > $$(IMAGE_BOOT_DIR)/boot-$(1)/fuboot_blobs.h
	cd $$(IMAGE_BOOT_DIR)/boot-$(1) && $$(XCHAIN)gcc $$(subst flow/boot,.,$$(VCU118_FUBOOT_CFLAGS)) -DFUBOOT_AUTOBOOT \
		-o fuboot_rom.elf $$(notdir $$(VCU118_FUBOOT_SRCS))
	$$(XCHAIN)objcopy -O binary $$(IMAGE_BOOT_DIR)/boot-$(1)/fuboot_rom.elf $$(IMAGE_BOOT_DIR)/boot-$(1)/fuboot_rom.bin
	flow/build_fuboot_rom.sh $$(IMAGE_BOOT_DIR)/boot-$(1)/fuboot_rom.bin \
		$$(KARUDEB_OPENSBI) $$(FUBOOT_OPENSBI_OFF) \
		$$(IMAGE_BOOT_DIR)/$(3).bin $$(FUBOOT_UBOOT_OFF) \
		$(2) $$(FUBOOT_DTB_OFF) $$@ $$(FUBOOT_ROM_BYTES)
endef
$(eval $(call IMAGE_BOOT_ROM,zkr,$(IMAGE_BOOT_ZKR_DTB),payload-seed))
$(eval $(call IMAGE_BOOT_ROM,zkr-off,$(IMAGE_BOOT_ZKR_DTB),payload-off))
$(eval $(call IMAGE_BOOT_ROM,no-zkr,$(IMAGE_BOOT_PLAIN_DTB),payload-seed))
.PHONY: image-boot-sim image-boot-test
image-boot-sim: $(VCU118_AUTH_ROM_HEX)
	$(MAKE) DDR_SIM_DIR=$(IMAGE_BOOT_DIR)/obj \
		KARU_DEFINES='$(filter-out KARU_ICACHE,$(RVA23_SHIP_SYN_DEFINES)) KARU_DBG $(VCU118_DBG_EXT_DEFINES)' \
		DDR_VFLAGS_EXTRA='-Idbg -GRAM_XADR=25 -GRESET_PC=65536 -GCPU_CLK_HZ=1000000 -GZKR_SAMPLE_DIV=8 -GZKR_INTERVAL=1 -GAUTH_ROM_HEX=\"$(abspath $(VCU118_AUTH_ROM_HEX))\"' \
		DDR_RTL='$(DDR_RTL) $(ZVK_RTL) $(ZKR_RTL) $(IMAGE_BOOT_DBG_RTL)' \
		$(IMAGE_BOOT_SIM)
image-boot-test: image-boot-sim $(IMAGE_BOOT_DIR)/zkr.rom.hex $(IMAGE_BOOT_DIR)/zkr-off.rom.hex $(IMAGE_BOOT_DIR)/no-zkr.rom.hex
	: > $(IMAGE_BOOT_DIR)/empty.hex
	python3 test/dbg/image_boot_test.py --sim $(IMAGE_BOOT_SIM) --dir $(IMAGE_BOOT_DIR) -- $(IMAGE_BOOT_RUN)

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

# The software reset request takes the same path as ndmreset. Two mutants
# must fail: one that leaves the UI side out of the software reset, and one
# that shortens the held pulse to a single cycle.
dbg-fpga-reset-test: $(BUILD)/dbg/tb_fpga_reset.vvp
	vvp $< | tee $(BUILD)/dbg/fpga-reset.log
	grep -q 'PASS FPGA debug reset ordering' $(BUILD)/dbg/fpga-reset.log
	mkdir -p $(BUILD)/dbg/fpga-reset-mutants
	sed 's/|| ndmreset_i || soft_reset || ui_arst_i/|| ndmreset_i || ui_arst_i/' dbg/karudbg_fpga_reset.v \
	  > $(BUILD)/dbg/fpga-reset-mutants/no_ui.v
	sed "s/count   <= HOLD_CYCLES\[CW-1:0\] - 1'b1;/count   <= {CW{1'b0}};/" flow/fpga/karu_soft_reset.v \
	  > $(BUILD)/dbg/fpga-reset-mutants/short.v
	test "$$(diff dbg/karudbg_fpga_reset.v $(BUILD)/dbg/fpga-reset-mutants/no_ui.v | grep -c '^>')" = 1
	test "$$(diff flow/fpga/karu_soft_reset.v $(BUILD)/dbg/fpga-reset-mutants/short.v | grep -c '^>')" = 1
	iverilog -g2012 -s tb_fpga_reset -o $(BUILD)/dbg/fpga-reset-mutants/no_ui.vvp test/dbg/tb_fpga_reset.sv \
	  $(BUILD)/dbg/fpga-reset-mutants/no_ui.v dbg/karudbg_reset.v flow/fpga/reset_ctrl.v flow/fpga/karu_soft_reset.v
	iverilog -g2012 -DKARU_NO_ASSERT -s tb_fpga_reset -o $(BUILD)/dbg/fpga-reset-mutants/short.vvp test/dbg/tb_fpga_reset.sv \
	  dbg/karudbg_fpga_reset.v dbg/karudbg_reset.v flow/fpga/reset_ctrl.v $(BUILD)/dbg/fpga-reset-mutants/short.v
	@for m in no_ui short; do \
	  if vvp -n $(BUILD)/dbg/fpga-reset-mutants/$$m.vvp > $(BUILD)/dbg/fpga-reset-mutants/$$m.log 2>&1 && \
	     grep -q 'PASS FPGA debug reset ordering' $(BUILD)/dbg/fpga-reset-mutants/$$m.log; then \
	    echo "FPGA reset mutant $$m NOT detected"; exit 1; fi; \
	  echo "detected FPGA reset mutant $$m: $$(grep -m1 -o 'Expected both.*\|Software reset.*' $(BUILD)/dbg/fpga-reset-mutants/$$m.log)"; done
	@# The held reset feeds asynchronous reset inputs: it must be one flop's
	@# output (security review 2026-11-15, S10). A combinational version fails.
	python3 test/dbg/check_output_flop.py --top karu_soft_reset --port reset_o \
	  --out $(BUILD)/dbg/fpga-reset-mutants/flop flow/fpga/karu_soft_reset.v
	python3 test/dbg/soft_reset_comb_mutant.py flow/fpga/karu_soft_reset.v $(BUILD)/dbg/fpga-reset-mutants/comb.v
	@if python3 test/dbg/check_output_flop.py --top karu_soft_reset --port reset_o \
	  --out $(BUILD)/dbg/fpga-reset-mutants/comb $(BUILD)/dbg/fpga-reset-mutants/comb.v \
	  > $(BUILD)/dbg/fpga-reset-mutants/comb.log 2>&1; then \
	  cat $(BUILD)/dbg/fpga-reset-mutants/comb.log; echo 'combinational soft reset mutant not detected'; exit 1; fi
	grep -q 'FAIL karu_soft_reset.reset_o: not driven directly by one flop' $(BUILD)/dbg/fpga-reset-mutants/comb.log
	@echo 'PASS soft reset single-flop check, combinational mutant detected'
	@# The board top itself is not simulated; check its reset wiring on the
	@# parsed netlist, with the request tied to 0 as a negative control.
	python3 test/dbg/check_soft_reset_wiring.py --out $(BUILD)/dbg/fpga-reset-mutants/wiring --mutant

$(BUILD)/dbg/tb_fpga_reset.vvp: test/dbg/tb_fpga_reset.sv dbg/karudbg_fpga_reset.v dbg/karudbg_reset.v flow/fpga/reset_ctrl.v flow/fpga/karu_soft_reset.v
	mkdir -p $(BUILD)/dbg
	iverilog -g2012 -s tb_fpga_reset -o $@ $^

dbg-bscan-protocol-test: $(BUILD)/dbg/tb_bscan_protocol.vvp
	vvp $< | tee $(BUILD)/dbg/bscan-protocol.log
	grep -q 'PASS BSCAN protocol' $(BUILD)/dbg/bscan-protocol.log

dbg-bscan-negative-test:
	python3 test/dbg/test_bscan_negative.py --out $(BUILD)/dbg/bscan-negative

# Truncated USER4 frames without outer TLR (S9). The negative control removes
# the tunnel's resynchronizing inner-TRST pulse and must fail the same bench.
DBG_BSCAN_TRUNC_DIR = $(BUILD)/dbg/bscan-truncate
DBG_BSCAN_TRUNC_SRCS = test/dbg/tb_bscan_remote.v test/dbg/xilinx_tap_model.v test/dbg/tb_jtag_remote.v dbg/karudbg_reset.v $(KARUDBG_JTAG_SRCS) dbg/karudbg.v dbg/karudbg_sba.v dbg/karudbg_rom.v
.PHONY: dbg-bscan-truncate-test
dbg-bscan-truncate-test: $(DBG_BSCAN_TRUNC_DIR)/tb_bscan_truncate.vvp $(DBG_BSCAN_TRUNC_DIR)/tb_bscan_truncate_mutant.vvp
	timeout 120 vvp -n $< | tee $(DBG_BSCAN_TRUNC_DIR)/truncate.log
	grep -q 'PASS bscan truncated USER4 scan recovery' $(DBG_BSCAN_TRUNC_DIR)/truncate.log
	@if timeout 120 vvp -n $(DBG_BSCAN_TRUNC_DIR)/tb_bscan_truncate_mutant.vvp \
	  > $(DBG_BSCAN_TRUNC_DIR)/negative-no-trst.log 2>&1; then \
	  echo 'no-recovery-pulse negative control did not fail'; exit 1; fi
	@if grep -q 'PASS bscan truncated' $(DBG_BSCAN_TRUNC_DIR)/negative-no-trst.log; then \
	  echo 'no-recovery-pulse negative control printed PASS'; exit 1; fi
	grep -q 'FAIL cut@.*phantom DMI request in next frames' $(DBG_BSCAN_TRUNC_DIR)/negative-no-trst.log

$(DBG_BSCAN_TRUNC_DIR)/tb_bscan_truncate.vvp: test/dbg/tb_bscan_truncate.sv dbg/karudbg_bscan_tunnel.v $(DBG_BSCAN_TRUNC_SRCS)
	mkdir -p $(@D)
	iverilog -g2012 -Idbg -s tb_bscan_truncate -o $@ $^

$(DBG_BSCAN_TRUNC_DIR)/tb_bscan_truncate_mutant.vvp: test/dbg/tb_bscan_truncate.sv $(DBG_BSCAN_TRUNC_DIR)/karudbg_bscan_tunnel_no_trst.v $(DBG_BSCAN_TRUNC_SRCS)
	iverilog -g2012 -Idbg -s tb_bscan_truncate -o $@ $^

# Mutant: the incomplete-frame capture no longer pulses the inner TRST.
# Exactly one line must change, or the mutation has gone stale.
$(DBG_BSCAN_TRUNC_DIR)/karudbg_bscan_tunnel_no_trst.v: dbg/karudbg_bscan_tunnel.v
	mkdir -p $(@D)
	sed 's/\(phase != PAD) inner_trst_n_q <=\) 1.b0;/\1 1; \/\/ MUTANT: no recovery pulse/' $< > $@.tmp
	@test "$$(diff $< $@.tmp | grep -c '^>')" = 1 || \
	  { echo 'no-TRST mutation no longer applies to $<'; rm -f $@.tmp; exit 1; }
	mv $@.tmp $@

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
