# Physical-board debug acceptance harness (test/dbg/board/). The phases need
# the VCU118; these targets are what can run without it. Included by the
# repository Makefile. SPDX-License-Identifier: BSD-2-Clause
DBG_BOARD_SRC        = test/dbg/board
DBG_BOARD_OUT       ?= $(BUILD)/dbg/board-accept
DBG_BOARD_REHEARSAL  = $(BUILD)/dbg/board-rehearsal
DBG_BOARD_MUTANT_DIR = $(DBG_BOARD_REHEARSAL)/mutant
DBG_BOARD_PAYLOAD_FLAGS = -march=rv64gcv_zicsr_zifencei_zawrs -mabi=lp64d -nostdlib -static

# The fixture that baremetal_phase.py loads into the board's scratch SRAM.
# The phases read payload.bin and payload.symbols from their artifact
# directory (KARU_BOARD_OUT, default $(DBG_BOARD_OUT)).
#
# Where the scratch SRAM is depends on the image under test, so the link
# address is not written here: the rule asks boardlib.py, which has the map
# of every image kind, and the phases refuse a fixture linked for another.
#   DBG_BOARD_IMAGE    image kind: rom2m-auth (the default), rom2m, rom1m
#   DBG_BOARD_SCRATCH  scratch SRAM base, for a map that is none of those
# They default to KARU_BOARD_IMAGE and KARU_BOARD_SCRATCH, the settings the
# phases read. The rule always runs, so that a change of image kind takes
# effect.
DBG_BOARD_IMAGE   ?= $(KARU_BOARD_IMAGE)
DBG_BOARD_SCRATCH ?= $(KARU_BOARD_SCRATCH)
.PHONY: dbg-board-fixture dbg-board-fixture-always
dbg-board-fixture: $(DBG_BOARD_OUT)/payload.symbols
$(DBG_BOARD_OUT)/payload.symbols $(DBG_BOARD_REHEARSAL)/payload.symbols $(DBG_BOARD_REHEARSAL)/rom1m/payload.symbols: \
  %/payload.symbols: $(DBG_BOARD_SRC)/payload.S $(DBG_BOARD_SRC)/boardlib.py dbg/board.mk dbg-board-fixture-always
	mkdir -p $(@D)
	address=$$(KARU_BOARD_OUT=$(@D) KARU_BOARD_IMAGE=$(DBG_BOARD_IMAGE) KARU_BOARD_SCRATCH=$(DBG_BOARD_SCRATCH) \
	    python3 $(DBG_BOARD_SRC)/boardlib.py) && echo "fixture linked at $$address" && \
	  $(XCHAIN)gcc $(DBG_BOARD_PAYLOAD_FLAGS) -Wl,-Ttext=$$address,--no-relax -o $(@D)/payload.elf $<
	$(XCHAIN)objcopy -O binary -j .text $(@D)/payload.elf $(@D)/payload.bin
	$(XCHAIN)nm -n $(@D)/payload.elf > $@
# The rehearsal's fixtures: for the simulated target, and for the 1 MiB map
# as a negative control. Not the caller's choice of board image.
$(DBG_BOARD_REHEARSAL)/payload.symbols: override DBG_BOARD_IMAGE = sim
$(DBG_BOARD_REHEARSAL)/rom1m/payload.symbols: override DBG_BOARD_IMAGE = rom1m
$(DBG_BOARD_REHEARSAL)/payload.symbols $(DBG_BOARD_REHEARSAL)/rom1m/payload.symbols: override DBG_BOARD_SCRATCH =

# Offline self-test with a stand-in for OpenOCD's Tcl RPC: every script
# compiles, a phase's exit status follows its case results, the image kinds
# agree with the RTL, a fixture for another map is refused, and the reset
# vector expected after reset-halt is the image kind's.
.PHONY: dbg-board-harness-test
dbg-board-harness-test:
	python3 $(DBG_BOARD_SRC)/test_boardlib.py --out $(BUILD)/dbg/board-harness-test > $(BUILD)/dbg/board-harness-test.log 2>&1 \
	  || { tail -5 $(BUILD)/dbg/board-harness-test.log; exit 1; }
	@grep 'board harness self-test: PASS' $(BUILD)/dbg/board-harness-test.log

# Rehearsal of board cases on the simulated full-debug target, through the
# same harness and an OpenOCD on remote_bitbang. The mutant model is
# dbg/karudbg.v with selectable autoexec defects (autoexec_mutant.py): it
# must pass with no defect selected, and the board autoexec case must fail
# for each defect. +autoexec_wany is visible only through writes of
# unselected registers.
#
# The simulated target has its own map (the scratch SRAM of
# rtl/karu_bootmap.vh, reset vector 0x8000_0000), which rehearse.py selects
# as image kind "sim". On it the "load" case, reset-halt with the exact DPC
# and the fixture written to scratch and read back, must pass. It must fail
# when another reset vector is expected (0x10000, the default board image's,
# and 0x80000004, one instruction on), and with the 1 MiB map, whose fixture
# address is ROM on this target.
$(DBG_BOARD_MUTANT_DIR)/obj/Vtb_jtag_core: $(DBG_BOARD_SRC)/autoexec_mutant.py test/dbg/tb_jtag_core.v \
  test/dbg/karudbg_test_ram.sv test/dbg/remote_bitbang.cc dbg/karudbg.f $(filter %.v,$(shell cat dbg/karudbg.f)) \
  $(wildcard rtl/*.vh rtl/*.sv dbg/*.vh) dbg/board.mk
	mkdir -p $(DBG_BOARD_MUTANT_DIR)
	python3 $(DBG_BOARD_SRC)/autoexec_mutant.py --out $(DBG_BOARD_MUTANT_DIR)/karudbg.v
	verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Irtl -Idbg $(DBG_OPENOCD_FLAGS) -DKARU_DBG_FULL \
	  --top-module tb_jtag_core --Mdir $(DBG_BOARD_MUTANT_DIR)/obj -CFLAGS -DKARUDBG_CORE_TARGET \
	  test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv \
	  $(filter-out dbg/karudbg.v,$(filter %.v,$(shell cat dbg/karudbg.f))) $(DBG_BOARD_MUTANT_DIR)/karudbg.v \
	  $(abspath test/dbg/remote_bitbang.cc) > $(DBG_BOARD_MUTANT_DIR)/build.log 2>&1

DBG_BOARD_REHEARSE = python3 $(DBG_BOARD_SRC)/rehearse.py --openocd $(OPENOCD) --out $(DBG_BOARD_REHEARSAL)
.PHONY: dbg-board-rehearsal-test
dbg-board-rehearsal-test: dbg-full-model $(DBG_BOARD_MUTANT_DIR)/obj/Vtb_jtag_core $(DBG_BOARD_REHEARSAL)/payload.symbols \
  $(DBG_BOARD_REHEARSAL)/rom1m/payload.symbols
	$(DBG_BOARD_REHEARSE) --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core --tag full autoexec
	$(DBG_BOARD_REHEARSE) --model $(DBG_BOARD_MUTANT_DIR)/obj/Vtb_jtag_core --tag mutant-off autoexec
	$(DBG_BOARD_REHEARSE) --model $(DBG_BOARD_MUTANT_DIR)/obj/Vtb_jtag_core --tag autoexec-dead \
	  --plusarg +autoexec_dead --expect-fail 'autoexec bit 1: exactly one execution per access' autoexec
	$(DBG_BOARD_REHEARSE) --model $(DBG_BOARD_MUTANT_DIR)/obj/Vtb_jtag_core --tag autoexec-any \
	  --plusarg +autoexec_any --expect-fail 'autoexec bit 0: exactly one execution per access' autoexec
	$(DBG_BOARD_REHEARSE) --model $(DBG_BOARD_MUTANT_DIR)/obj/Vtb_jtag_core --tag autoexec-wany \
	  --plusarg +autoexec_wany --expect-fail 'autoexec bit 0: exactly one execution per access' autoexec
	$(DBG_BOARD_REHEARSE) --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core --tag load load
	$(DBG_BOARD_REHEARSE) --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core --tag load-reset-auth \
	  --reset-pc 0x10000 --expect-fail 'reset-halt DPC before first instruction' load
	$(DBG_BOARD_REHEARSE) --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core --tag load-reset-next \
	  --reset-pc 0x80000004 --expect-fail 'reset-halt DPC before first instruction' load
	python3 $(DBG_BOARD_SRC)/rehearse.py --openocd $(OPENOCD) --out $(DBG_BOARD_REHEARSAL)/rom1m \
	  --model $(BUILD)/dbg/obj_jtag_core_full/Vtb_jtag_core --tag load-rom1m \
	  --scratch 0x101000 --expect-fail 'write_memory 0x108000' load

# GetNoise: raw noise capture from the entropy source (getnoise_capture.py,
# needs an image with KARU_ZKR). getnoise.S is position independent and is
# linked at 0, so getnoise.symbols holds offsets from the load address.
DBG_GETNOISE_TEST  = $(BUILD)/dbg/getnoise-test
DBG_GETNOISE_FLAGS = -march=rv64gc_zicsr -mabi=lp64d -nostdlib -static -Wl,-Ttext=0,--no-relax,-e,getnoise
.PHONY: dbg-getnoise-fixture
dbg-getnoise-fixture: $(DBG_BOARD_OUT)/getnoise.symbols
$(DBG_BOARD_OUT)/getnoise.symbols $(DBG_GETNOISE_TEST)/getnoise.symbols: %/getnoise.symbols: $(DBG_BOARD_SRC)/getnoise.S dbg/board.mk
	mkdir -p $(@D)
	$(XCHAIN)gcc $(DBG_GETNOISE_FLAGS) -o $(@D)/getnoise.elf $<
	$(XCHAIN)objcopy -O binary -j .text $(@D)/getnoise.elf $(@D)/getnoise.bin
	$(XCHAIN)nm -n $(@D)/getnoise.elf > $@

# Offline self-test of the capture payload, the capture phase and the
# analysis (test_getnoise.py): the payload runs on the Zkr simulation bench,
# the phase against a stand-in for OpenOCD that runs the same bench, the
# analysis on data generated from the model. Not part of a gate list.
.PHONY: dbg-getnoise-test
dbg-getnoise-test: $(DBG_GETNOISE_TEST)/getnoise.symbols $(ZKR_DIR)/Vhtif_h/Vhtif_tb
	python3 $(DBG_BOARD_SRC)/test_getnoise.py --out $(DBG_GETNOISE_TEST) --bench $(ZKR_DIR)/Vhtif_h/Vhtif_tb \
	  --xchain $(XCHAIN) > $(BUILD)/dbg/getnoise-test.log 2>&1 || { tail -5 $(BUILD)/dbg/getnoise-test.log; exit 1; }
	@grep 'getnoise self-test: PASS' $(BUILD)/dbg/getnoise-test.log

# Debug authentication phase (auth_phase.py), rehearsed without a board:
# pristine OpenOCD and the phase with its own client against the simulated
# JTAG target running the real window ROM, the simulation ROM that
# dbg/auth.mk builds from test/dbg/auth_rom. auth_rehearse.py explains what
# stands in for the switches and the reset button. The first run covers the
# exchange, with a power-on reset before each "por" step; the next five the
# other strap settings. Then the negative controls: four clients with a
# wrong TEST computation must fail to unlock, and four cases started with
# the wrong straps must stop with the message that names them. Last, the
# board's OpenOCD configuration is parsed with a dummy adapter: it must
# leave the target unexamined. Not part of a gate list.
DBG_BOARD_AUTH    = $(BUILD)/dbg/board-auth-rehearsal
DBG_BOARD_AUTH_TB ?= test/dbg/tb_jtag_core.v
$(DBG_BOARD_AUTH)/obj/Vtb_jtag_core: $(DBG_BOARD_AUTH_TB) test/dbg/karudbg_test_ram.sv test/dbg/remote_bitbang.cc \
  dbg/karudbg.f $(filter %.v,$(shell cat dbg/karudbg.f)) $(wildcard rtl/*.vh rtl/*.sv dbg/*.vh) $(DBG_AUTH_WIN_DIR)/rom.hex dbg/board.mk
	mkdir -p $(DBG_BOARD_AUTH)
	timeout 900 verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DKARU_NO_V \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_WIN_DIR)/rom.hex)"' --top-module tb_jtag_core --Mdir $(DBG_BOARD_AUTH)/obj \
	  -CFLAGS -DKARUDBG_CORE_TARGET $(DBG_BOARD_AUTH_TB) test/dbg/karudbg_test_ram.sv -f dbg/karudbg.f \
	  $(abspath test/dbg/remote_bitbang.cc) > $(DBG_BOARD_AUTH)/build.log 2>&1 || { tail -20 $(DBG_BOARD_AUTH)/build.log; exit 1; }

DBG_BOARD_AUTH_RUN = python3 $(DBG_BOARD_SRC)/auth_rehearse.py --openocd $(OPENOCD) --out $(DBG_BOARD_AUTH) \
	--model $(DBG_BOARD_AUTH)/obj/Vtb_jtag_core
DBG_BOARD_AUTH_UNLOCK = 'did not rise after a correct TEST response'
.PHONY: dbg-board-auth-rehearsal-test
dbg-board-auth-rehearsal-test: $(DBG_BOARD_AUTH)/obj/Vtb_jtag_core
	$(DBG_BOARD_AUTH_RUN) --tag window locked wrong-response por expiry por authenticate por replay por fresh-nonce
	grep -q 'Debugger is not authenticated to target Debug Module' $(DBG_BOARD_AUTH)/window-openocd.log
	$(DBG_BOARD_AUTH_RUN) --tag no-hold --plusarg +auth_hold=0 no-hold
	$(DBG_BOARD_AUTH_RUN) --tag entropy-off --plusarg +auth_trng_opst=0 entropy-off
	$(DBG_BOARD_AUTH_RUN) --tag entropy-dead --plusarg +auth_trng_opst=3 entropy-off
	$(DBG_BOARD_AUTH_RUN) --tag disabled --plusarg +auth_lc=2 disabled
	$(DBG_BOARD_AUTH_RUN) --tag open --plusarg +auth_lc=0 open
	$(DBG_BOARD_AUTH_RUN) --tag mutant-key --mutate key --expect-fail $(DBG_BOARD_AUTH_UNLOCK) authenticate
	$(DBG_BOARD_AUTH_RUN) --tag mutant-rotation --mutate rotation --expect-fail $(DBG_BOARD_AUTH_UNLOCK) authenticate
	$(DBG_BOARD_AUTH_RUN) --tag mutant-mask --mutate mask --expect-fail $(DBG_BOARD_AUTH_UNLOCK) authenticate
	$(DBG_BOARD_AUTH_RUN) --tag mutant-fold --mutate fold --expect-fail $(DBG_BOARD_AUTH_UNLOCK) authenticate
	$(DBG_BOARD_AUTH_RUN) --tag straps-open --plusarg +auth_lc=0 --expect-fail 'shows lifecycle OPEN' authenticate
	$(DBG_BOARD_AUTH_RUN) --tag straps-no-hold --plusarg +auth_hold=0 --expect-fail 'switch 3 is off' authenticate
	$(DBG_BOARD_AUTH_RUN) --tag straps-hold --expect-fail 'switch 3 is on' no-hold
	$(DBG_BOARD_AUTH_RUN) --tag straps-auth --expect-fail 'needs lifecycle DISABLED' disabled
	$(DBG_BOARD_AUTH_RUN) --tag no-record --expect-fail 'no accepted response on record' replay
	printf 'adapter driver dummy\n' > $(DBG_BOARD_AUTH)/dummy-adapter.cfg
	KARU_BOARD_RPC=127.0.0.1:0 KARU_BOARD_GDB_REMOTE=127.0.0.1:0 KARU_BOARD_ADAPTER_CFG=$(abspath $(DBG_BOARD_AUTH)/dummy-adapter.cfg) \
	  timeout 60 $(OPENOCD) -f $(DBG_BOARD_SRC)/auth-server.cfg \
	  -c 'echo "locked-target server: examined=[karu.cpu was_examined] defer=[karu.cpu cget -defer-examine]"' -c shutdown \
	  > $(DBG_BOARD_AUTH)/board-config.log 2>&1 || true
	grep -q 'locked-target server: examined=0 defer=true' $(DBG_BOARD_AUTH)/board-config.log
	@echo "PASS board authentication rehearsal: exchange, straps, 4 client mutants, 5 wrong setups, board configuration parsed"

# The authentication rehearsal is one of the functional gates. dbg/checks.mk
# lists the others; this one is declared here, with its target.
dbg-functional-gates: dbg-board-auth-rehearsal-test
