# karudbg authentication (plan A1). Included by the root Makefile.
DBG_AUTH_DIR ?= $(BUILD)/dbg/auth

# $(call dbg_auth_mutant,name,sed expression,expected failure text)
define dbg_auth_mutant
	mkdir -p $(DBG_AUTH_DIR)/mut-$(1)
	sed '$(2)' dbg/karudbg_auth.v > $(DBG_AUTH_DIR)/mut-$(1)/karudbg_auth.v
	! cmp -s dbg/karudbg_auth.v $(DBG_AUTH_DIR)/mut-$(1)/karudbg_auth.v
	iverilog -g2012 -s tb_auth -o $(DBG_AUTH_DIR)/mut-$(1)/tb.vvp test/dbg/tb_auth.sv $(DBG_AUTH_DIR)/mut-$(1)/karudbg_auth.v
	@if timeout 60 vvp -n $(DBG_AUTH_DIR)/mut-$(1)/tb.vvp > $(DBG_AUTH_DIR)/mut-$(1)/run.log 2>&1; then \
	  echo 'mutant $(1) NOT detected'; exit 1; fi
	grep -q '$(3)' $(DBG_AUTH_DIR)/mut-$(1)/run.log
	@echo 'detected mutant $(1): $(3)'
endef

.PHONY: dbg-auth-unit-test
dbg-auth-unit-test:
	mkdir -p $(DBG_AUTH_DIR)
	verilator --lint-only -Wall -Idbg --top-module karudbg_auth dbg/karudbg_auth.v
	python3 flow/asic/lint_decl.py dbg/karudbg_auth.v
	iverilog -g2001 -s karudbg_auth -o $(DBG_AUTH_DIR)/parse.vvp dbg/karudbg_auth.v
	iverilog -g2012 -s tb_auth -o $(DBG_AUTH_DIR)/tb_auth.vvp test/dbg/tb_auth.sv dbg/karudbg_auth.v
	timeout 60 vvp -n $(DBG_AUTH_DIR)/tb_auth.vvp > $(DBG_AUTH_DIR)/unit.log 2>&1 || { cat $(DBG_AUTH_DIR)/unit.log; exit 1; }
	grep 'karudbg_auth unit: PASS' $(DBG_AUTH_DIR)/unit.log
	$(call dbg_auth_mutant,no_request_needed,s/lc_auth \&\& auth_req_q \&\& !boot_done_q/lc_auth \&\& !boot_done_q/,no unlock without REQUEST\|auth_unlock rose outside)
	$(call dbg_auth_mutant,unlock_beats_trap,s/ \&\& !boot_exit_now \&\& !sess_close_now;/ \&\& !sess_close_now;/; s/ \&\& !core_in_reset_i \&\& !trap_i \&\& !dbg_enter_i;/ \&\& !core_in_reset_i;/,trap in the unlock cycle wins)
	$(call dbg_auth_mutant,no_relock_reset,s/assign relock_d = .*/assign relock_d = 1'"'"'b0;/,relock resets a Debug-Mode hart)
	$(call dbg_auth_mutant,no_session_close,s/assign boot_done_set = boot_exit_now || sess_close_now ||/assign boot_done_set = boot_exit_now ||/,deactivation after consumption closes\|left the window open)
	$(call dbg_auth_mutant,unlock_beats_session_reset,s/ \&\& !boot_exit_now \&\& !sess_close_now;/ \&\& !boot_exit_now;/,session reset dominates a same-cycle unlock)
	$(call dbg_auth_mutant,hold_in_open,s/hold_q <= hold_strap_i \&\& lc_i == LC_AUTH;/hold_q <= hold_strap_i;/,OPEN boots normally\|in OPEN without revocation)
	$(call dbg_auth_mutant,no_reset_close,s/sess_close_now || reset_close ||/sess_close_now ||/,system reset in the window\|system reset after boot left)
	$(call dbg_auth_mutant,csr_live_in_reset,s/assign csr_live = csr_fire_i \&\& !core_in_reset_i \&\& !trap_i \&\& !dbg_enter_i;/assign csr_live = csr_fire_i \&\& !trap_i \&\& !dbg_enter_i;/,in a reset cycle\|unlock committed outside)
	$(call dbg_auth_mutant,unlock_from_debug_mode,s/!virt_i \&\& !debug_mode_i \&\&$$/!virt_i \&\&/,no unlock from Debug Mode\|unlock committed outside)
	$(call dbg_auth_mutant,window_never_expires,s/assign win_expire = (WINDOW_LOG2 != 0) \&\& win_open \&\& win_cnt\[WINDOW_LOG2\];/assign win_expire = 1'"'"'b0;/,window limit)
	$(call dbg_auth_mutant,unlock_in_the_expiry_clock,s/^        !win_expire \&\&$$/        1'"'"'b1 \&\&/,one clock after the window limit is refused\|expired and the window stayed open or unlocked)
	$(call dbg_auth_mutant,window_one_clock_short,s/if (win_open \&\& !win_cnt\[WINDOW_LOG2\]) win_cnt <= win_cnt + 1'"'"'b1;/if (win_open \&\& !win_cnt[WINDOW_LOG2]) win_cnt <= win_cnt + (win_cnt == 0 ? 2 : 1);/,in the last clock of the window commits)
	$(call dbg_auth_mutant,window_restarts_with_the_hart,s/if (win_open \&\& !win_cnt\[WINDOW_LOG2\]) win_cnt <= win_cnt + 1'"'"'b1;/if (core_in_reset_i) win_cnt <= 0; else if (win_open \&\& !win_cnt[WINDOW_LOG2]) win_cnt <= win_cnt + 1'"'"'b1;/,a hart held in reset does not stop the window timer)

# DM + authentication block together (KARU_DBG_AUTH).
DBG_AUTH_DM_SRCS = dbg/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v dbg/karudbg_auth.v
# $(call dbg_auth_dm_mutant,name,sed expression on karudbg.v,expected failure text)
define dbg_auth_dm_mutant
	mkdir -p $(DBG_AUTH_DIR)/dm-mut-$(1)
	sed '$(2)' dbg/karudbg.v > $(DBG_AUTH_DIR)/dm-mut-$(1)/karudbg.v
	! cmp -s dbg/karudbg.v $(DBG_AUTH_DIR)/dm-mut-$(1)/karudbg.v
	iverilog -g2012 -Idbg -DKARU_DBG_AUTH -s tb_dm_auth -o $(DBG_AUTH_DIR)/dm-mut-$(1)/tb.vvp \
	  test/dbg/tb_dm_auth.sv $(DBG_AUTH_DIR)/dm-mut-$(1)/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v dbg/karudbg_auth.v
	@if timeout 60 vvp -n $(DBG_AUTH_DIR)/dm-mut-$(1)/tb.vvp > $(DBG_AUTH_DIR)/dm-mut-$(1)/run.log 2>&1; then \
	  echo 'DM mutant $(1) NOT detected'; exit 1; fi
	grep -q '$(3)' $(DBG_AUTH_DIR)/dm-mut-$(1)/run.log
	@echo 'detected DM mutant $(1): $(3)'
endef

# Island hostile-response tests (lemma C9, cut K3). The mutant restores the
# pre-fix owner-only response mux on the dmem read channel.
DBG_AUTH_ISLAND_MUT = $(DBG_AUTH_DIR)/island-mut
.PHONY: dbg-auth-island-test
dbg-auth-island-test:
	mkdir -p $(DBG_AUTH_ISLAND_MUT)
	verilator --lint-only $(LINT_W) -Irtl -Idbg --top-module karudbg_island dbg/karudbg_island.v dbg/karudbg_axi.v
	iverilog -g2012 -Irtl -Idbg -s tb_island -o $(DBG_AUTH_DIR)/tb_island.vvp test/dbg/tb_island.sv dbg/karudbg_island.v dbg/karudbg_axi.v
	timeout 120 vvp -n $(DBG_AUTH_DIR)/tb_island.vvp > $(DBG_AUTH_DIR)/island.log 2>&1 || { tail $(DBG_AUTH_DIR)/island.log; exit 1; }
	grep 'karudbg island: PASS' $(DBG_AUTH_DIR)/island.log
	sed -e 's/assign up_dmem_rvalid = dr_out && (dr_owner ? d_rvalid : dn_dmem_rvalid);/assign up_dmem_rvalid = dr_owner ? d_rvalid : dn_dmem_rvalid;/' \
	    -e 's/assign dn_dmem_rready = up_dmem_rready && dr_out && !dr_owner;/assign dn_dmem_rready = up_dmem_rready \&\& !dr_owner;/' \
	    -e 's/[$$]fatal(1, "karudbg_island:/$$display("disabled karudbg_island:/' \
	    dbg/karudbg_island.v > $(DBG_AUTH_ISLAND_MUT)/karudbg_island.v
	test "$$(diff dbg/karudbg_island.v $(DBG_AUTH_ISLAND_MUT)/karudbg_island.v | grep -c '^>')" = 5
	iverilog -g2012 -Irtl -Idbg -s tb_island -o $(DBG_AUTH_ISLAND_MUT)/tb.vvp test/dbg/tb_island.sv \
	  $(DBG_AUTH_ISLAND_MUT)/karudbg_island.v dbg/karudbg_axi.v
	@if timeout 120 vvp -n $(DBG_AUTH_ISLAND_MUT)/tb.vvp > $(DBG_AUTH_ISLAND_MUT)/run.log 2>&1; then \
	  echo 'island owner-only mutant NOT detected'; exit 1; fi
	# Local island assertions are disabled in the mutant: the bench's own
	# data and consumption checks must catch it.
	grep -Eq 'island check [0-9]+: .*(returns island data|response beat|external beat consumed)' $(DBG_AUTH_ISLAND_MUT)/run.log
	@echo "detected island mutant owner_only_mux: $$(grep -Em1 'island check' $(DBG_AUTH_ISLAND_MUT)/run.log)"
	# Mutant: outstanding flags survive reset, so an external beat after a
	# reset can complete a read issued before it.
	mkdir -p $(DBG_AUTH_ISLAND_MUT)-reset
	sed -e 's/            im_out <= 0; dr_out <= 0;/            ;/' \
	    -e 's/[$$]fatal(1, "karudbg_island:/$$display("disabled karudbg_island:/' \
	    dbg/karudbg_island.v > $(DBG_AUTH_ISLAND_MUT)-reset/karudbg_island.v
	test "$$(diff dbg/karudbg_island.v $(DBG_AUTH_ISLAND_MUT)-reset/karudbg_island.v | grep -c '^>')" = 4
	iverilog -g2012 -Irtl -Idbg -s tb_island -o $(DBG_AUTH_ISLAND_MUT)-reset/tb.vvp test/dbg/tb_island.sv \
	  $(DBG_AUTH_ISLAND_MUT)-reset/karudbg_island.v dbg/karudbg_axi.v
	@if timeout 120 vvp -n $(DBG_AUTH_ISLAND_MUT)-reset/tb.vvp > $(DBG_AUTH_ISLAND_MUT)-reset/run.log 2>&1; then \
	  echo 'island reset mutant NOT detected'; exit 1; fi
	grep -Eq 'island check [0-9]+: .*(after a reset|after reset)' $(DBG_AUTH_ISLAND_MUT)-reset/run.log
	@echo "detected island mutant outstanding_survives_reset: $$(grep -Em1 'island check' $(DBG_AUTH_ISLAND_MUT)-reset/run.log)"

.PHONY: dbg-auth-dm-test dbg-auth-open-equiv-test
dbg-auth-dm-test:
	mkdir -p $(DBG_AUTH_DIR)
	verilator --lint-only -Wall -Idbg -DKARU_DBG_AUTH --top-module karudbg dbg/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v
	verilator --lint-only -Wall -Idbg -DKARU_DBG_AUTH -DKARU_DBG_SBA -DKARU_DBG_AUTOEXEC --top-module karudbg dbg/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v
	iverilog -g2001 -Idbg -DKARU_DBG_AUTH -s karudbg -o $(DBG_AUTH_DIR)/dm-parse.vvp dbg/karudbg.v dbg/karudbg_rom.v dbg/karudbg_sba.v
	iverilog -g2012 -Idbg -DKARU_DBG_AUTH -s tb_dm_auth -o $(DBG_AUTH_DIR)/tb_dm_auth.vvp test/dbg/tb_dm_auth.sv $(DBG_AUTH_DM_SRCS)
	timeout 60 vvp -n $(DBG_AUTH_DIR)/tb_dm_auth.vvp > $(DBG_AUTH_DIR)/dm.log 2>&1 || { cat $(DBG_AUTH_DIR)/dm.log; exit 1; }
	grep 'karudbg DM auth: PASS' $(DBG_AUTH_DIR)/dm.log
	$(call dbg_auth_dm_mutant,ndmreset_old_gate,s/if (!dbg_en_next) ndmreset_q <= 0;/if (!dbg_en) ndmreset_q <= 0;/,clears on the gate.s falling edge\|DM output asserted while locked)
	$(call dbg_auth_dm_mutant,no_safe_sequence,s/mem_rdata_o = dbg_en ? {abstract_word/mem_rdata_o = 1'"'"'b1 ? {abstract_word/,abstract words are EBREAK\|executing hart sees EBREAK)
	$(call dbg_auth_dm_mutant,locked_view_leak,s/if (dmactive_q \&\& !dbg_en) begin/if (1'"'"'b0) begin/,locked DMI read disclosed\|AUTH locked: DMI)

# Contract 7: KARU_DBG_AUTH with the gate tied open is sequentially
# equivalent to today's DM (base and SBA+autoexec), and a gate leak fails.
dbg-auth-open-equiv-test:
	timeout 600 python3 test/dbg/check_auth_open_equiv.py --out $(DBG_AUTH_DIR)/equiv-base
	timeout 900 python3 test/dbg/check_auth_open_equiv.py --out $(DBG_AUTH_DIR)/equiv-full -D KARU_DBG_SBA -D KARU_DBG_AUTOEXEC
	timeout 600 python3 test/dbg/check_auth_open_equiv.py --out $(DBG_AUTH_DIR)/equiv-mut --mutate

# Real core: boot hold, ROM window, unlock, revocation, OPEN (KARU_DBG_AUTH).
DBG_AUTH_CORE_DIR ?= $(BUILD)/dbg/auth-core
DBG_AUTH_CORE_FLAGS ?= -DKARU_NO_V
$(DBG_AUTH_CORE_DIR)/rom.hex: test/dbg/auth_rom_stub.S
	mkdir -p $(DBG_AUTH_CORE_DIR)
	$(XCHAIN)gcc -march=rv64gc -mabi=lp64d -nostdlib -static -Wl,-Ttext=0x10000 -o $(DBG_AUTH_CORE_DIR)/rom.elf $<
	$(XCHAIN)objcopy -O binary $(DBG_AUTH_CORE_DIR)/rom.elf $(DBG_AUTH_CORE_DIR)/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_CORE_DIR)/rom.bin > $@
$(DBG_AUTH_CORE_DIR)/Vtb_auth_core: test/dbg/tb_auth_core.sv test/dbg/karudbg_test_ram.sv test/dbg/trigger_checker.vh $(DBG_CORE_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv) dbg/auth.mk $(DBG_AUTH_CORE_DIR)/rom.hex
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH $(DBG_AUTH_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_CORE_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_CORE_DIR) --top-module tb_auth_core test/dbg/tb_auth_core.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)

.PHONY: dbg-auth-core-test
dbg-auth-core-test: $(DBG_AUTH_CORE_DIR)/Vtb_auth_core
	timeout 300 $< > $(DBG_AUTH_CORE_DIR)/run.log 2>&1 || { tail -20 $(DBG_AUTH_CORE_DIR)/run.log; exit 1; }
	grep 'karudbg auth actual core: PASS' $(DBG_AUTH_CORE_DIR)/run.log
	# Mutant: no core-side gate (EBREAK and every entry source ungated).
	# The DM gate alone cannot stop a dcsr.ebreakm entry after firmware
	# revocation; the bench or INV42 must catch it.
	mkdir -p $(DBG_AUTH_CORE_DIR)/mut-core-gate
	sed -e 's/ex_sub == `SYS_EBREAK \&\& dbg_ebreak \&\& dbg_en;/ex_sub == `SYS_EBREAK \&\& dbg_ebreak;/' \
	    -e 's/assign dbg_enter = !debug_mode \&\& dbg_en \&\& (/assign dbg_enter = !debug_mode \&\& (/' \
	    rtl/karu64.v > $(DBG_AUTH_CORE_DIR)/mut-core-gate/karu64.v
	test "$$(diff rtl/karu64.v $(DBG_AUTH_CORE_DIR)/mut-core-gate/karu64.v | grep -c '^>')" = 2
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH $(DBG_AUTH_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_CORE_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_CORE_DIR)/mut-core-gate/obj --top-module tb_auth_core test/dbg/tb_auth_core.sv test/dbg/karudbg_test_ram.sv \
	  $(filter-out rtl/karu64.v,$(DBG_CORE_RTL)) $(DBG_AUTH_CORE_DIR)/mut-core-gate/karu64.v > $(DBG_AUTH_CORE_DIR)/mut-core-gate/build.log 2>&1
	@if timeout 300 $(DBG_AUTH_CORE_DIR)/mut-core-gate/obj/Vtb_auth_core > $(DBG_AUTH_CORE_DIR)/mut-core-gate/run.log 2>&1; then \
	  echo 'core-gate mutant NOT detected'; exit 1; fi
	grep -Eq 'INV42a|no Debug Mode entry|breakpoint' $(DBG_AUTH_CORE_DIR)/mut-core-gate/run.log
	@echo "detected core-gate mutant: $$(grep -Em1 'INV42a|no Debug Mode entry|breakpoint' $(DBG_AUTH_CORE_DIR)/mut-core-gate/run.log)"
	# Mutant: both response layers back to the pre-fix owner-only muxes
	# (island and debug-page router), with their local assertions disabled.
	# Either fixed layer alone stops the forged load on the real core
	# (defence in depth); the island layer alone is covered by
	# dbg-auth-island-test and the router alone by dbg-run-control-test.
	mkdir -p $(DBG_AUTH_CORE_DIR)/mut-island
	sed -e 's/assign up_dmem_rvalid = dr_out && (dr_owner ? d_rvalid : dn_dmem_rvalid);/assign up_dmem_rvalid = dr_owner ? d_rvalid : dn_dmem_rvalid;/' \
	    -e 's/assign dn_dmem_rready = up_dmem_rready && dr_out && !dr_owner;/assign dn_dmem_rready = up_dmem_rready \&\& !dr_owner;/' \
	    -e 's/[$$]fatal(1, "karudbg_island:/$$display("disabled karudbg_island:/' \
	    dbg/karudbg_island.v > $(DBG_AUTH_CORE_DIR)/mut-island/karudbg_island.v
	test "$$(diff dbg/karudbg_island.v $(DBG_AUTH_CORE_DIR)/mut-island/karudbg_island.v | grep -c '^>')" = 5
	sed -e 's/assign c_dmem_rvalid=dr_out \&\& (dr_owner ? d_rvalid : x_dmem_rvalid);/assign c_dmem_rvalid=dr_owner ? d_rvalid : x_dmem_rvalid;/' \
	    -e 's/assign x_dmem_rready=c_dmem_rready \&\& dr_out \&\& !dr_owner;/assign x_dmem_rready=c_dmem_rready \&\& !dr_owner;/' \
	    -e 's/[$$]fatal(1, "karudbg_core:/$$display("disabled karudbg_core:/' \
	    dbg/karudbg_core.v > $(DBG_AUTH_CORE_DIR)/mut-island/karudbg_core.v
	test "$$(diff dbg/karudbg_core.v $(DBG_AUTH_CORE_DIR)/mut-island/karudbg_core.v | grep -c '^>')" = 4
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH $(DBG_AUTH_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_CORE_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_CORE_DIR)/mut-island/obj --top-module tb_auth_core test/dbg/tb_auth_core.sv test/dbg/karudbg_test_ram.sv \
	  $(filter-out dbg/karudbg_island.v dbg/karudbg_core.v,$(DBG_CORE_RTL)) $(DBG_AUTH_CORE_DIR)/mut-island/karudbg_island.v \
	  $(DBG_AUTH_CORE_DIR)/mut-island/karudbg_core.v > $(DBG_AUTH_CORE_DIR)/mut-island/build.log 2>&1
	@if timeout 300 $(DBG_AUTH_CORE_DIR)/mut-island/obj/Vtb_auth_core > $(DBG_AUTH_CORE_DIR)/mut-island/run.log 2>&1; then \
	  echo 'island mutant NOT detected on the real core'; exit 1; fi
	grep -q 'forged island response cannot unlock' $(DBG_AUTH_CORE_DIR)/mut-island/run.log
	@echo "detected real-core island+router mutant: forged island response cannot unlock"

# A4, revocation with an SBA transaction in flight (plan 3.5): the real
# karudbg_core with SBA and the ROM stub, four-state (Icarus, with
# KARU_ASIC). The hart keeps using the data bus. The bench holds the R or B
# beat of an accepted SBA read or write and revokes (revoke_i, or the hart's
# fw_lock), releasing the beat from fall-1 to fall+40; it also revokes with
# the SBA address stalled at the fabric, with a request not yet accepted,
# and with the hart in Debug Mode and the R beat withheld (relock reset).
# Checks on the dmem port and the DMI only (test/dbg/tb_auth_sba_revoke.sv);
# about 6 s per run, 35 s with the mutants. Each mutant disables the RTL
# assertion that would see it first, and must be reported by the named
# bench check and by none of the excluded ones.
DBG_AUTH_SBA_REVOKE_DIR ?= $(BUILD)/dbg/auth-sba-revoke
DBG_AUTH_SBA_REVOKE_IV = iverilog -g2012 -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DKARU_DBG_SBA \
  -DKARU_NO_V -DKARU_NO_F -DKARU_ASIC -s tb_auth_sba_revoke \
  -Ptb_auth_sba_revoke.ROM_HEX='"$(abspath $(DBG_AUTH_CORE_DIR)/rom.hex)"'
DBG_AUTH_SBA_REVOKE_PASS = karudbg auth SBA revocation: PASS
# $(call dbg_auth_sba_revoke_mutant,name,patched files,expected check,excluded checks ERE)
define dbg_auth_sba_revoke_mutant
	rm -rf $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1) && mkdir -p $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/dbg
	cp $(2) $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/dbg/
	patch -s -N --fuzz=0 --no-backup-if-mismatch -r - -p1 -d $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1) \
	  < test/dbg/auth_sba_revoke_mut_$(1).patch || { echo 'mutant $(1) no longer applies'; exit 1; }
	for f in $(2); do ! cmp -s $$f $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/$$f || { echo "mutant $(1) left $$f unchanged"; exit 1; }; done
	timeout 300 $(DBG_AUTH_SBA_REVOKE_IV) -o $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/tb.vvp test/dbg/tb_auth_sba_revoke.sv \
	  test/dbg/karudbg_test_ram.sv $(filter-out $(2),$(DBG_CORE_RTL)) $(addprefix $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/,$(2))
	@if timeout 600 vvp -n $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/tb.vvp > $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log 2>&1 || \
	  grep -q '$(DBG_AUTH_SBA_REVOKE_PASS)' $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log; then \
	  echo 'mutant $(1) NOT detected'; exit 1; fi
	@grep -q 'FAIL \[$(3)\]' $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log || \
	  { grep -v readmemh $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log | tail -20; echo 'mutant $(1): no [$(3)] failure'; exit 1; }
	@! grep -Em3 'FAIL \[($(4))\]' $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log || \
	  { echo 'mutant $(1) was caught by an excluded check'; exit 1; }
	@echo "detected mutant $(1): $$(grep -c 'FAIL \[$(3)\]' $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log) [$(3)] failures, first: $$(grep -m1 'FAIL \[$(3)\]' $(DBG_AUTH_SBA_REVOKE_DIR)/mut-$(1)/run.log)"
endef

.PHONY: dbg-auth-sba-revoke-test
dbg-auth-sba-revoke-test: $(DBG_AUTH_CORE_DIR)/rom.hex
	mkdir -p $(DBG_AUTH_SBA_REVOKE_DIR)
	timeout 300 $(DBG_AUTH_SBA_REVOKE_IV) -o $(DBG_AUTH_SBA_REVOKE_DIR)/tb.vvp test/dbg/tb_auth_sba_revoke.sv \
	  test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL)
	timeout 600 vvp -n $(DBG_AUTH_SBA_REVOKE_DIR)/tb.vvp > $(DBG_AUTH_SBA_REVOKE_DIR)/run.log 2>&1 || \
	  { grep -v readmemh $(DBG_AUTH_SBA_REVOKE_DIR)/run.log | tail -30; exit 1; }
	grep '^scenario' $(DBG_AUTH_SBA_REVOKE_DIR)/run.log
	grep '$(DBG_AUTH_SBA_REVOKE_PASS)' $(DBG_AUTH_SBA_REVOKE_DIR)/run.log
	# The SBA engine is gated by dmactive only: it launches after the fall.
	$(call dbg_auth_sba_revoke_mutant,launch,dbg/karudbg.v,LAUNCH,LEAK|AXI)
	# The drained read data reaches the debugger (four layers removed).
	$(call dbg_auth_sba_revoke_mutant,leak,dbg/karudbg.v dbg/karudbg_sba.v,LEAK,LAUNCH|AXI)
	# The response is not absorbed after the fall: the hart loses the bus.
	$(call dbg_auth_sba_revoke_mutant,no_drain,dbg/karudbg_sba.v,HART,LEAK|LAUNCH|AXI)

# KARU_DBG_AUTH with lc=OPEN on the full real-core debug bench must match the
# build without authentication cycle for cycle: same checks, cycles and
# retirements (contract 7).
.PHONY: dbg-core-auth-open-test dbg-auth-test
dbg-core-auth-open-test: dbg-core-test
	$(MAKE) DBG_CORE_DIR=$(BUILD)/dbg/core-auth-open DBG_CORE_FLAGS='-DKARU_NO_V -DKARU_DBG_AUTH' dbg-core-test
	grep 'karudbg actual core: PASS' $(DBG_CORE_DIR)/run.log > $(BUILD)/dbg/core-auth-open/base-summary.txt
	grep 'karudbg actual core: PASS' $(BUILD)/dbg/core-auth-open/run.log > $(BUILD)/dbg/core-auth-open/auth-summary.txt
	cmp $(BUILD)/dbg/core-auth-open/base-summary.txt $(BUILD)/dbg/core-auth-open/auth-summary.txt
	@echo "PASS lc=OPEN real core identical: $$(cat $(BUILD)/dbg/core-auth-open/auth-summary.txt)"

dbg-auth-test: dbg-auth-unit-test dbg-auth-island-test dbg-auth-dm-test dbg-auth-open-equiv-test dbg-auth-core-test \
 dbg-auth-openocd-test dbg-auth-window-test dbg-auth-window-seed-test dbg-auth-window-noseed-test \
 dbg-core-auth-open-test

# Pristine pinned OpenOCD against a KARU_DBG_AUTH JTAG model (contract 2):
# examine fails while locked, the authdata mailbox authenticates through the
# island ROM stub, arp_examine attaches, and a dmactive pulse keeps the grant.
DBG_AUTH_OCD_DIR ?= $(BUILD)/dbg/auth-openocd
$(DBG_AUTH_OCD_DIR)/Vtb_jtag_core: test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv test/dbg/remote_bitbang.cc \
  dbg/karudbg.f $(filter %.v,$(shell cat dbg/karudbg.f)) $(wildcard rtl/*.vh rtl/*.sv dbg/*.vh) $(DBG_AUTH_CORE_DIR)/rom.hex dbg/auth.mk
	mkdir -p $(DBG_AUTH_OCD_DIR)
	timeout 900 verilator --cc --exe --build -j $(DBG_JOBS) -Wno-fatal -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DKARU_NO_V \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_CORE_DIR)/rom.hex)"' --top-module tb_jtag_core --Mdir $(DBG_AUTH_OCD_DIR) \
	  -CFLAGS -DKARUDBG_CORE_TARGET test/dbg/tb_jtag_core.v test/dbg/karudbg_test_ram.sv -f dbg/karudbg.f \
	  $(abspath test/dbg/remote_bitbang.cc) > $(DBG_AUTH_OCD_DIR)/build.log 2>&1

.PHONY: dbg-auth-openocd-test
dbg-auth-openocd-test: $(DBG_AUTH_OCD_DIR)/Vtb_jtag_core
	python3 test/dbg/run_openocd_transport.py --model $< --openocd $(OPENOCD) --out $(DBG_AUTH_OCD_DIR) \
	  --config test/dbg/openocd_auth.cfg --marker 'PASS OpenOCD debug authentication' --timeout 90
	grep -q 'Debugger is not authenticated to target Debug Module' $(DBG_AUTH_OCD_DIR)/openocd-jtag.log
	@echo "PASS pristine OpenOCD: locked examine refused, authenticated attach succeeded"
	python3 test/dbg/run_openocd_transport.py --model $< --openocd $(OPENOCD) --out $(DBG_AUTH_OCD_DIR)/reject \
	  --config test/dbg/openocd_auth_reject.cfg --marker 'PASS OpenOCD rejected authentication stays locked' --timeout 90

# A2: simulation island ROM running the contract's frame protocol with the
# simulation-only TEST algorithm (the production algorithm awaits D3).
DBG_AUTH_WIN_DIR ?= $(BUILD)/dbg/auth-window
DBG_AUTH_ROM_CFLAGS = -march=rv64imac_zicsr -mabi=lp64 -Os -ffreestanding -nostdlib -static -mcmodel=medany -fno-pic
DBG_AUTH_ROM_BYPASS = s/if (expired()) return 0;/if (expired() \&\& !(csr_read(CSR_RX) >> 32)) return 0;/
DBG_AUTH_ROM_SRCS = test/dbg/auth_rom/start.S test/dbg/auth_rom/window.c test/dbg/auth_rom/rom.ld
# The ROM polls seed for its nonce, at most TRNG_TRIES + 1 times per word
# without getting one, and window.c states how many clocks one poll takes,
# least and most (TRNG_POLL_CLOCKS, TRNG_POLL_CLOCKS_MAX): the limit is sized
# from them. The window bench measures the poll and holds it to that range,
# so its runs are given the three constants as window.c has them.
# $(call dbg_auth_rom_const,NAME) is shell text that prints one of them.
dbg_auth_rom_const = grep -m1 -o 'define $(1) [0-9]*' test/dbg/auth_rom/window.c | cut -d' ' -f3
DBG_AUTH_POLL_ARGS = +trng_tries=$$($(call dbg_auth_rom_const,TRNG_TRIES)) +poll_clocks=$$($(call dbg_auth_rom_const,TRNG_POLL_CLOCKS)) \
  +poll_clocks_max=$$($(call dbg_auth_rom_const,TRNG_POLL_CLOCKS_MAX))
# Algorithm 0x04, the SHA3-256 shared-secret MAC (contract 5.1), which the
# FPGA image verifies: window.c built with -DAUTH_ALG_SHA3, sha3.c and a key
# header written by key_header.py. Simulation builds use the PUBLIC test key
# test/dbg/auth_rom/test_key.txt; dbg/fpga.mk generates the board's key.
DBG_AUTH_SHA3_SRCS = test/dbg/auth_rom/sha3.c test/dbg/auth_rom/sha3.h test/dbg/auth_rom/key_header.py
DBG_AUTH_TEST_KEY = test/dbg/auth_rom/test_key.txt
DBG_AUTH_TEST_KEY_H = $(BUILD)/dbg/auth-test-key/test_key.h
$(DBG_AUTH_TEST_KEY_H): $(DBG_AUTH_TEST_KEY) test/dbg/auth_rom/key_header.py
	mkdir -p $(@D)
	python3 test/dbg/auth_rom/key_header.py $< $@
DBG_AUTH_SHA3_FLAGS = -DAUTH_ALG_SHA3 -DAUTH_KEY_HEADER=\"$(abspath $(DBG_AUTH_TEST_KEY_H))\"
# The simulation SHA3 ROM: the TEST ROM's constants, algorithm 0x04.
DBG_AUTH_SHA3_DIR ?= $(DBG_AUTH_WIN_DIR)/sha3
$(DBG_AUTH_SHA3_DIR)/rom.hex: $(DBG_AUTH_ROM_SRCS) $(DBG_AUTH_SHA3_SRCS) $(DBG_AUTH_TEST_KEY_H)
	mkdir -p $(DBG_AUTH_SHA3_DIR)
	$(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) $(DBG_AUTH_SHA3_FLAGS) -T test/dbg/auth_rom/rom.ld -o $(DBG_AUTH_SHA3_DIR)/rom.elf \
	  test/dbg/auth_rom/start.S test/dbg/auth_rom/window.c test/dbg/auth_rom/sha3.c
	$(XCHAIN)objcopy -O binary -j .text $(DBG_AUTH_SHA3_DIR)/rom.elf $(DBG_AUTH_SHA3_DIR)/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_SHA3_DIR)/rom.bin > $@
	$(XCHAIN)size $(DBG_AUTH_SHA3_DIR)/rom.elf
$(DBG_AUTH_WIN_DIR)/rom.hex: $(DBG_AUTH_ROM_SRCS)
	mkdir -p $(DBG_AUTH_WIN_DIR)
	$(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) -T test/dbg/auth_rom/rom.ld -o $(DBG_AUTH_WIN_DIR)/rom.elf \
	  test/dbg/auth_rom/start.S test/dbg/auth_rom/window.c
	$(XCHAIN)objcopy -O binary -j .text $(DBG_AUTH_WIN_DIR)/rom.elf $(DBG_AUTH_WIN_DIR)/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_WIN_DIR)/rom.bin > $@
	$(XCHAIN)size $(DBG_AUTH_WIN_DIR)/rom.elf
# The ROM draws its nonce from seed, so the core has KARU_ZKR and the bench a
# stand-in behind it (test/dbg/karudbg_test_seed.v) whose words it chooses.
$(DBG_AUTH_WIN_DIR)/Vtb_auth_window: test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv test/dbg/karudbg_test_seed.v test/dbg/trigger_checker.vh $(DBG_CORE_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv) dbg/auth.mk $(DBG_AUTH_WIN_DIR)/rom.hex
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DKARU_ZKR $(DBG_AUTH_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_WIN_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_WIN_DIR) --top-module tb_auth_window test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv test/dbg/karudbg_test_seed.v $(DBG_CORE_RTL)

# The polling limit on the real core. With the ROM's own TRNG_TRIES the
# limit is far beyond the simulation window, so a source that never delivers
# is ended by the deadline. A ROM built with a small TRNG_TRIES shows the
# limit itself: the wait ends at poll TRNG_TRIES + 1, a word that comes after
# TRNG_TRIES polls without one is still taken, and one poll more is given up
# on. Two mutants of it must fail: no limit at all, and one poll early.
DBG_AUTH_TRIES_SMALL = 300
DBG_AUTH_TRIES_DIR = $(DBG_AUTH_WIN_DIR)/tries
# $(call dbg_auth_tries_rom,directory,window.c)
define dbg_auth_tries_rom
	$(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) -DTRNG_TRIES=$(DBG_AUTH_TRIES_SMALL) -T test/dbg/auth_rom/rom.ld -o $(1)/rom.elf test/dbg/auth_rom/start.S $(2)
	$(XCHAIN)objcopy -O binary -j .text $(1)/rom.elf $(1)/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(1)/rom.bin > $(1)/rom.hex
endef
$(DBG_AUTH_TRIES_DIR)/rom.hex: $(DBG_AUTH_ROM_SRCS) dbg/auth.mk
	mkdir -p $(DBG_AUTH_TRIES_DIR)/nolimit $(DBG_AUTH_TRIES_DIR)/early
	sed 's/opst == 3 || ++tries > TRNG_TRIES/opst == 3/' test/dbg/auth_rom/window.c > $(DBG_AUTH_TRIES_DIR)/nolimit/window.c
	sed 's/++tries > TRNG_TRIES/++tries >= TRNG_TRIES/' test/dbg/auth_rom/window.c > $(DBG_AUTH_TRIES_DIR)/early/window.c
	test "$$(diff test/dbg/auth_rom/window.c $(DBG_AUTH_TRIES_DIR)/nolimit/window.c | grep -c '^>')" = 1
	test "$$(diff test/dbg/auth_rom/window.c $(DBG_AUTH_TRIES_DIR)/early/window.c | grep -c '^>')" = 1
	$(call dbg_auth_tries_rom,$(DBG_AUTH_TRIES_DIR)/nolimit,$(DBG_AUTH_TRIES_DIR)/nolimit/window.c)
	$(call dbg_auth_tries_rom,$(DBG_AUTH_TRIES_DIR)/early,$(DBG_AUTH_TRIES_DIR)/early/window.c)
	$(call dbg_auth_tries_rom,$(DBG_AUTH_TRIES_DIR),test/dbg/auth_rom/window.c)

# The same bench around a core built as the VCU118 debug image's: the defines
# of IMAGE_DEFINES in test/dbg/check_auth_bypass.py that reach the core. One
# poll of seed takes longer there (77 clocks against 53), and the ROM's limit
# is sized for both. Only the cases of a source that does not deliver run on
# it.
# The bench is built beside the other one, not below it: Verilator's makefile
# searches the parent directory, and would take the other build's
# precompiled header for its own.
DBG_AUTH_IMAGE_DIR = $(DBG_AUTH_WIN_DIR)-image
DBG_AUTH_IMAGE_CORE_FLAGS = -DKARU_DBG_FULL -DKARU_RVA23S64 -DKARU_ICACHE -DKARU_ZVK -DKARU_KECCAK -DKARU_V_MUL_CYCLES=16 \
  -DKARU_V_DIV_CYCLES=64 -DKARU_V_LANE_PIPE -DKARU_V_CWB_STAGE -DKARU_SMCNTRPMF -DKARU_SSCOFPMF
$(DBG_AUTH_IMAGE_DIR)/Vtb_auth_window: test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv test/dbg/karudbg_test_seed.v test/dbg/trigger_checker.vh $(DBG_CORE_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv) dbg/auth.mk $(DBG_AUTH_WIN_DIR)/rom.hex
	mkdir -p $(DBG_AUTH_IMAGE_DIR)
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DKARU_ZKR $(DBG_AUTH_IMAGE_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_WIN_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_IMAGE_DIR) --top-module tb_auth_window test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv test/dbg/karudbg_test_seed.v $(DBG_CORE_RTL) \
	  > $(DBG_AUTH_IMAGE_DIR)/build.log 2>&1 || { tail -20 $(DBG_AUTH_IMAGE_DIR)/build.log; exit 1; }

# +deadline_addr is the ROM's deadline variable, for the bench's monitor.
# The mutant ROM has the reviewed defect: an available RX word bypasses the
# deadline, and nothing checks it before the grant. The boundary sweep must
# catch it on the real core.
# The same bench with the entropy source of the FPGA image behind seed, with
# its behavioural noise model, in place of the bench's stand-in. Every case
# of the bench runs again.
DBG_AUTH_SEED_DIR ?= $(DBG_AUTH_WIN_DIR)/seed
$(DBG_AUTH_SEED_DIR)/rom.hex: $(DBG_AUTH_ROM_SRCS)
	mkdir -p $(DBG_AUTH_SEED_DIR)
	$(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) -T test/dbg/auth_rom/rom.ld -o $(DBG_AUTH_SEED_DIR)/rom.elf \
	  test/dbg/auth_rom/start.S test/dbg/auth_rom/window.c
	$(XCHAIN)objcopy -O binary -j .text $(DBG_AUTH_SEED_DIR)/rom.elf $(DBG_AUTH_SEED_DIR)/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_SEED_DIR)/rom.bin > $@
$(DBG_AUTH_SEED_DIR)/Vtb_auth_window: test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv test/dbg/trigger_checker.vh $(DBG_CORE_RTL) $(ZKR_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv) dbg/auth.mk $(DBG_AUTH_SEED_DIR)/rom.hex
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DKARU_ZKR -DAUTH_WINDOW_ENTROPY_SRC $(DBG_AUTH_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_SEED_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_SEED_DIR) --top-module tb_auth_window test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL) $(ZKR_RTL)
.PHONY: dbg-auth-window-seed-test
dbg-auth-window-seed-test: $(DBG_AUTH_SEED_DIR)/Vtb_auth_window
	timeout 900 $< +deadline_addr=$$($(XCHAIN)nm $(DBG_AUTH_SEED_DIR)/rom.elf | awk '$$3=="deadline"{print $$1}') \
	  > $(DBG_AUTH_SEED_DIR)/run.log 2>&1 || { tail -20 $(DBG_AUTH_SEED_DIR)/run.log; exit 1; }
	grep 'nonce source: seed, the entropy source' $(DBG_AUTH_SEED_DIR)/run.log
	grep 'karudbg auth window ROM: PASS' $(DBG_AUTH_SEED_DIR)/run.log

# A core without Zkr has no seed CSR, so no nonce source. Its ROM is built
# with -DAUTH_NO_SEED (dbg/fpga.mk does that for an image with KARU_DBG_AUTH
# and no KARU_ZKR): it accepts a REQUEST, makes no challenge, never unlocks,
# and must still hand over to the next stage. The window bench without
# KARU_ZKR and with that ROM, in the SHA3 build with the public test key as
# the board's ROM is: with a REQUEST and without one. Two controls, each of
# which must fail: the ROM built without the flag (it reads seed, an illegal
# instruction with no trap vector set), and a ROM whose make_nonce() reports
# success without a source (a challenge with a constant nonce).
DBG_AUTH_NOSEED_DIR ?= $(DBG_AUTH_WIN_DIR)/noseed
DBG_AUTH_NOSEED_CC = $(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) $(DBG_AUTH_SHA3_FLAGS) -DAUTH_NO_SEED -Itest/dbg/auth_rom -T test/dbg/auth_rom/rom.ld
$(DBG_AUTH_NOSEED_DIR)/rom.hex: $(DBG_AUTH_ROM_SRCS) $(DBG_AUTH_SHA3_SRCS) $(DBG_AUTH_TEST_KEY_H) dbg/auth.mk
	mkdir -p $(DBG_AUTH_NOSEED_DIR)/mut-nonce
	$(DBG_AUTH_NOSEED_CC) -o $(DBG_AUTH_NOSEED_DIR)/rom.elf test/dbg/auth_rom/start.S test/dbg/auth_rom/window.c test/dbg/auth_rom/sha3.c
	$(XCHAIN)objcopy -O binary -j .text $(DBG_AUTH_NOSEED_DIR)/rom.elf $(DBG_AUTH_NOSEED_DIR)/rom.bin
	sed -e '/^#ifdef AUTH_NO_SEED/,/^#else/ s/return 0;/return 1;/' test/dbg/auth_rom/window.c > $(DBG_AUTH_NOSEED_DIR)/mut-nonce/window.c
	test "$$(diff test/dbg/auth_rom/window.c $(DBG_AUTH_NOSEED_DIR)/mut-nonce/window.c | grep -c '^>')" = 1
	$(DBG_AUTH_NOSEED_CC) -o $(DBG_AUTH_NOSEED_DIR)/mut-nonce/rom.elf test/dbg/auth_rom/start.S $(DBG_AUTH_NOSEED_DIR)/mut-nonce/window.c test/dbg/auth_rom/sha3.c
	$(XCHAIN)objcopy -O binary -j .text $(DBG_AUTH_NOSEED_DIR)/mut-nonce/rom.elf $(DBG_AUTH_NOSEED_DIR)/mut-nonce/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_NOSEED_DIR)/mut-nonce/rom.bin > $(DBG_AUTH_NOSEED_DIR)/mut-nonce/rom.hex
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_NOSEED_DIR)/rom.bin > $@
$(DBG_AUTH_NOSEED_DIR)/Vtb_auth_window: test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv test/dbg/trigger_checker.vh $(DBG_CORE_RTL) $(wildcard dbg/*.vh rtl/*.vh rtl/*.sv) dbg/auth.mk $(DBG_AUTH_NOSEED_DIR)/rom.hex
	timeout 900 verilator --binary --timing -j $(DBG_JOBS) $(DBG_CORE_SIM_FLAGS) -Irtl -Idbg -DKARU_DBG -DKARU_DBG_AUTH -DAUTH_WINDOW_NO_SEED $(DBG_AUTH_CORE_FLAGS) $(LINT_W) \
	  -GROM_HEX='"$(abspath $(DBG_AUTH_NOSEED_DIR)/rom.hex)"' \
	  --Mdir $(DBG_AUTH_NOSEED_DIR) --top-module tb_auth_window test/dbg/tb_auth_window.sv test/dbg/karudbg_test_ram.sv $(DBG_CORE_RTL) \
	  > $(DBG_AUTH_NOSEED_DIR)/build.log 2>&1 || { tail -20 $(DBG_AUTH_NOSEED_DIR)/build.log; exit 1; }
.PHONY: dbg-auth-window-noseed-test
dbg-auth-window-noseed-test: $(DBG_AUTH_NOSEED_DIR)/Vtb_auth_window $(DBG_AUTH_SHA3_DIR)/rom.hex
	timeout 900 $< > $(DBG_AUTH_NOSEED_DIR)/run.log 2>&1 || { tail -20 $(DBG_AUTH_NOSEED_DIR)/run.log; exit 1; }
	grep 'next stage after' $(DBG_AUTH_NOSEED_DIR)/run.log
	grep 'karudbg auth window ROM without seed: PASS' $(DBG_AUTH_NOSEED_DIR)/run.log
	@if timeout 900 $< +rom=$(abspath $(DBG_AUTH_SHA3_DIR)/rom.hex) > $(DBG_AUTH_NOSEED_DIR)/mut-seed.log 2>&1; then \
	  echo 'a ROM that reads seed NOT detected on a core without Zkr'; exit 1; fi
	grep -q 'the ROM did not read seed' $(DBG_AUTH_NOSEED_DIR)/mut-seed.log
	@echo "detected ROM built without AUTH_NO_SEED: $$(grep -m1 'auth core check' $(DBG_AUTH_NOSEED_DIR)/mut-seed.log)"
	@if timeout 900 $< +rom=$(abspath $(DBG_AUTH_NOSEED_DIR)/mut-nonce/rom.hex) > $(DBG_AUTH_NOSEED_DIR)/mut-nonce.log 2>&1; then \
	  echo 'a no-seed ROM that makes a challenge NOT detected'; exit 1; fi
	grep -q 'no challenge word was pushed' $(DBG_AUTH_NOSEED_DIR)/mut-nonce.log
	@echo "detected no-seed ROM with a constant nonce: $$(grep -m1 'auth core check' $(DBG_AUTH_NOSEED_DIR)/mut-nonce.log)"

.PHONY: dbg-auth-window-test dbg-auth-rom-host-test
dbg-auth-window-test: $(DBG_AUTH_WIN_DIR)/Vtb_auth_window dbg-auth-rom-host-test $(DBG_AUTH_TRIES_DIR)/rom.hex $(DBG_AUTH_IMAGE_DIR)/Vtb_auth_window
	timeout 900 $< +deadline_addr=$$($(XCHAIN)nm $(DBG_AUTH_WIN_DIR)/rom.elf | awk '$$3=="deadline"{print $$1}') $(DBG_AUTH_POLL_ARGS) \
	  > $(DBG_AUTH_WIN_DIR)/run.log 2>&1 || { tail -20 $(DBG_AUTH_WIN_DIR)/run.log; exit 1; }
	grep 'seed polling: one poll' $(DBG_AUTH_WIN_DIR)/run.log
	grep 'karudbg auth window ROM: PASS' $(DBG_AUTH_WIN_DIR)/run.log
	@# the polling limit: a ROM in which it acts inside the window, and its two mutants
	timeout 900 $< +rom=$(abspath $(DBG_AUTH_TRIES_DIR)/rom.hex) +stall_only +trng_tries=$(DBG_AUTH_TRIES_SMALL) \
	  +deadline_addr=$$($(XCHAIN)nm $(DBG_AUTH_TRIES_DIR)/rom.elf | awk '$$3=="deadline"{print $$1}') \
	  > $(DBG_AUTH_TRIES_DIR)/run.log 2>&1 || { tail -20 $(DBG_AUTH_TRIES_DIR)/run.log; exit 1; }
	grep 'karudbg auth window ROM, seed polling limit: PASS' $(DBG_AUTH_TRIES_DIR)/run.log
	@for m in nolimit early; do d=$(DBG_AUTH_TRIES_DIR)/$$m; \
	  if timeout 900 $< +rom=$(abspath $(DBG_AUTH_TRIES_DIR))/$$m/rom.hex +stall_only +trng_tries=$(DBG_AUTH_TRIES_SMALL) \
	    +deadline_addr=$$($(XCHAIN)nm $$d/rom.elf | awk '$$3=="deadline"{print $$1}') > $$d/run.log 2>&1; then \
	    echo "polling-limit ROM mutant $$m NOT detected"; exit 1; fi; \
	  grep -q 'the per-word limit ended the wait' $$d/run.log || { echo "polling-limit ROM mutant $$m: unexpected failure"; tail -3 $$d/run.log; exit 1; }; \
	  echo "detected polling-limit ROM mutant $$m: $$(grep -m1 'auth core check' $$d/run.log)"; done
	@# the poll time against window.c, on this core and on a core built as the image's;
	@# a range that starts one clock above the poll measured here must fail
	timeout 900 $(DBG_AUTH_IMAGE_DIR)/Vtb_auth_window +stall_only $(DBG_AUTH_POLL_ARGS) \
	  +deadline_addr=$$($(XCHAIN)nm $(DBG_AUTH_WIN_DIR)/rom.elf | awk '$$3=="deadline"{print $$1}') \
	  > $(DBG_AUTH_IMAGE_DIR)/run.log 2>&1 || { tail -20 $(DBG_AUTH_IMAGE_DIR)/run.log; exit 1; }
	grep 'seed polling: one poll' $(DBG_AUTH_IMAGE_DIR)/run.log
	grep 'karudbg auth window ROM, seed polling limit: PASS' $(DBG_AUTH_IMAGE_DIR)/run.log
	@if timeout 900 $< +stall_only +trng_tries=$$($(call dbg_auth_rom_const,TRNG_TRIES)) \
	  +poll_clocks=$$(( $$($(call dbg_auth_rom_const,TRNG_POLL_CLOCKS)) + 1 )) +poll_clocks_max=$$($(call dbg_auth_rom_const,TRNG_POLL_CLOCKS_MAX)) \
	  +deadline_addr=$$($(XCHAIN)nm $(DBG_AUTH_WIN_DIR)/rom.elf | awk '$$3=="deadline"{print $$1}') \
	  > $(DBG_AUTH_WIN_DIR)/poll-control.log 2>&1; then echo 'a poll shorter than window.c assumes NOT detected'; exit 1; fi
	grep -q 'window.c assumes' $(DBG_AUTH_WIN_DIR)/poll-control.log
	@echo "detected a poll shorter than the assumed range: $$(grep -m1 'auth core check' $(DBG_AUTH_WIN_DIR)/poll-control.log)"
	mkdir -p $(DBG_AUTH_WIN_DIR)/mut-rom
	sed -e '/decision is inside the window/d' \
	    -e '/^static int rx_word/,/^}/ '"$(DBG_AUTH_ROM_BYPASS)" test/dbg/auth_rom/window.c > $(DBG_AUTH_WIN_DIR)/mut-rom/window.c
	test "$$(diff test/dbg/auth_rom/window.c $(DBG_AUTH_WIN_DIR)/mut-rom/window.c | grep -c '^>')" = 1
	$(XCHAIN)gcc $(DBG_AUTH_ROM_CFLAGS) -T test/dbg/auth_rom/rom.ld -o $(DBG_AUTH_WIN_DIR)/mut-rom/rom.elf \
	  test/dbg/auth_rom/start.S $(DBG_AUTH_WIN_DIR)/mut-rom/window.c
	$(XCHAIN)objcopy -O binary -j .text $(DBG_AUTH_WIN_DIR)/mut-rom/rom.elf $(DBG_AUTH_WIN_DIR)/mut-rom/rom.bin
	hexdump -v -e '1/8 "%016x\n"' $(DBG_AUTH_WIN_DIR)/mut-rom/rom.bin > $(DBG_AUTH_WIN_DIR)/mut-rom/rom.hex
	@if timeout 900 $< +rom=$(abspath $(DBG_AUTH_WIN_DIR)/mut-rom/rom.hex) \
	  +deadline_addr=$$($(XCHAIN)nm $(DBG_AUTH_WIN_DIR)/mut-rom/rom.elf | awk '$$3=="deadline"{print $$1}') \
	  > $(DBG_AUTH_WIN_DIR)/mut-rom/run.log 2>&1; then echo 'late-response ROM mutant NOT detected'; exit 1; fi
	grep -Eq 'no (grant|response word popped) after the deadline' $(DBG_AUTH_WIN_DIR)/mut-rom/run.log
	@echo "detected ROM mutant: $$(grep -m1 'auth core check' $(DBG_AUTH_WIN_DIR)/mut-rom/run.log)"

# The same window.c on a host mailbox model with one cycle per CSR access:
# exact deadline boundaries, queued responses, repeated ABORTs, random
# schedules. Each mutant removes one deadline check and must fail; `bypass`
# is the reviewed defect (an available RX word skips the deadline).
#
# The polling limit of the nonce source, with a TRNG_TRIES that acts inside
# the model's window: a source that never delivers is given up on at poll
# TRNG_TRIES + 1, and a word that comes after TRNG_TRIES polls without one
# is waited for, each of the sixteen. Three mutants must fail: no limit
# (`tries`), one poll early (`tries1`), and a limit over all sixteen words
# together (`triesall`). With the ROM's own TRNG_TRIES the limit is beyond
# the model's window and the deadline must end the wait. Last, window.c for
# a production window of 2^30 cycles must compile with its own TRNG_TRIES,
# and must refuse 200,000 (under twice the longest wait for a word) and
# 20,000,000 (over a quarter of the window).
#
# Then algorithm 0x04 (HOST_SHA3): SHA3-256 against known answers and the
# MAC against its Python definition; the TEST ROM must reject a correct 0x04
# response, and the SHA3 ROM a correct TEST one, while the SHA3 ROM runs
# every schedule with 0x04 responses (a wrong one included). Two mutants
# must fail: a wrong Keccak round constant, and a wrong MAC label in window.c.
DBG_AUTH_ROM_HOST_DIR ?= $(BUILD)/dbg/auth-rom-host
DBG_AUTH_HOST_SHA3 = $(CC) -O2 -Wall -Wextra -Werror -DHOST_SHA3 -DAUTH_KEY_HEADER=\"$(abspath $(DBG_AUTH_TEST_KEY_H))\" -Itest/dbg/auth_rom
dbg-auth-rom-host-test: test/dbg/auth_rom/host_test.c test/dbg/auth_rom/window.c $(DBG_AUTH_SHA3_SRCS) $(DBG_AUTH_TEST_KEY_H)
	mkdir -p $(DBG_AUTH_ROM_HOST_DIR)/final $(DBG_AUTH_ROM_HOST_DIR)/rx $(DBG_AUTH_ROM_HOST_DIR)/push $(DBG_AUTH_ROM_HOST_DIR)/bypass
	mkdir -p $(DBG_AUTH_ROM_HOST_DIR)/tries $(DBG_AUTH_ROM_HOST_DIR)/tries1 $(DBG_AUTH_ROM_HOST_DIR)/triesall $(DBG_AUTH_ROM_HOST_DIR)/long
	$(CC) -O2 -Wall -Wextra -Werror -o $(DBG_AUTH_ROM_HOST_DIR)/host_test test/dbg/auth_rom/host_test.c
	$(DBG_AUTH_ROM_HOST_DIR)/host_test > $(DBG_AUTH_ROM_HOST_DIR)/run.log || { tail -3 $(DBG_AUTH_ROM_HOST_DIR)/run.log; exit 1; }
	@cat $(DBG_AUTH_ROM_HOST_DIR)/run.log
	grep -q 'the per-word limit ended the wait' $(DBG_AUTH_ROM_HOST_DIR)/run.log
	$(CC) -O2 -Wall -Wextra -Werror -DTRNG_TRIES=$$($(call dbg_auth_rom_const,TRNG_TRIES)) -o $(DBG_AUTH_ROM_HOST_DIR)/long/host_test test/dbg/auth_rom/host_test.c
	$(DBG_AUTH_ROM_HOST_DIR)/long/host_test > $(DBG_AUTH_ROM_HOST_DIR)/long/run.log || { tail -3 $(DBG_AUTH_ROM_HOST_DIR)/long/run.log; exit 1; }
	grep 'the deadline ended the wait' $(DBG_AUTH_ROM_HOST_DIR)/long/run.log
	$(CC) -fsyntax-only -Wall -Wextra -Werror -DAUTH_ROM_HOST -DWINDOW_CYCLES=1073741824ull test/dbg/auth_rom/window.c
	@for c in 200000:'under twice the longest wait' 20000000:'more than a quarter of the window'; do \
	  if $(CC) -fsyntax-only -DAUTH_ROM_HOST -DWINDOW_CYCLES=1073741824ull -DTRNG_TRIES=$${c%%:*} test/dbg/auth_rom/window.c \
	    > $(DBG_AUTH_ROM_HOST_DIR)/tries-$${c%%:*}.log 2>&1; then echo "TRNG_TRIES=$${c%%:*} with a production window NOT refused"; exit 1; fi; \
	  grep -q "$${c#*:}" $(DBG_AUTH_ROM_HOST_DIR)/tries-$${c%%:*}.log || { cat $(DBG_AUTH_ROM_HOST_DIR)/tries-$${c%%:*}.log; exit 1; }; \
	  echo "refused TRNG_TRIES=$${c%%:*} with a production window: $${c#*:}"; done
	sed 's/opst == 3 || ++tries > TRNG_TRIES/opst == 3/' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/tries/window.c
	sed 's/++tries > TRNG_TRIES/++tries >= TRNG_TRIES/' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/tries1/window.c
	sed 's/unsigned tries = 0;/static unsigned tries; if (i == 0) tries = 0;/' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/triesall/window.c
	sed '/decision is inside the window/d' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/final/window.c
	sed '/^static int rx_word/,/^}/ s/if (expired()) return 0;//' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/rx/window.c
	sed '/^static int push_challenge(void) {/,/^}/ s/if (expired()) return 0;//' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/push/window.c
	sed -e '/decision is inside the window/d' -e '/^static int rx_word/,/^}/ '"$(DBG_AUTH_ROM_BYPASS)" \
	  test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/bypass/window.c
	@for m in final rx push bypass tries tries1 triesall; do \
	  test "$$(diff test/dbg/auth_rom/window.c $(DBG_AUTH_ROM_HOST_DIR)/$$m/window.c | grep -c '^>')" -le 1 || exit 1; \
	  ! cmp -s test/dbg/auth_rom/window.c $(DBG_AUTH_ROM_HOST_DIR)/$$m/window.c || { echo "mutant $$m did not apply"; exit 1; }; \
	  cp test/dbg/auth_rom/host_test.c $(DBG_AUTH_ROM_HOST_DIR)/$$m/host_test.c; \
	  $(CC) -O2 -o $(DBG_AUTH_ROM_HOST_DIR)/$$m/host_test $(DBG_AUTH_ROM_HOST_DIR)/$$m/host_test.c || exit 1; \
	  if $(DBG_AUTH_ROM_HOST_DIR)/$$m/host_test > $(DBG_AUTH_ROM_HOST_DIR)/$$m/run.log 2>&1; then \
	    echo "ROM host mutant $$m NOT detected"; exit 1; fi; \
	  echo "detected ROM host mutant $$m: $$(tail -1 $(DBG_AUTH_ROM_HOST_DIR)/$$m/run.log)"; done
	mkdir -p $(DBG_AUTH_ROM_HOST_DIR)/sha3-test-rom $(DBG_AUTH_ROM_HOST_DIR)/sha3-rom $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-rc $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-label
	$(DBG_AUTH_HOST_SHA3) -o $(DBG_AUTH_ROM_HOST_DIR)/sha3-test-rom/host_test test/dbg/auth_rom/host_test.c test/dbg/auth_rom/sha3.c
	$(DBG_AUTH_ROM_HOST_DIR)/sha3-test-rom/host_test
	$(DBG_AUTH_HOST_SHA3) -DAUTH_ALG_SHA3 -o $(DBG_AUTH_ROM_HOST_DIR)/sha3-rom/host_test test/dbg/auth_rom/host_test.c test/dbg/auth_rom/sha3.c
	$(DBG_AUTH_ROM_HOST_DIR)/sha3-rom/host_test
	sed 's/0x8000000080008008ull/0x8000000080008009ull/' test/dbg/auth_rom/sha3.c > $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-rc/sha3.c
	sed 's/"karudbg-auth-v1"/"karudbg-auth-v2"/' test/dbg/auth_rom/window.c > $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-label/window.c
	! cmp -s test/dbg/auth_rom/sha3.c $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-rc/sha3.c
	! cmp -s test/dbg/auth_rom/window.c $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-label/window.c
	cp test/dbg/auth_rom/host_test.c $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-label/host_test.c
	$(DBG_AUTH_HOST_SHA3) -DAUTH_ALG_SHA3 -o $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-rc/host_test test/dbg/auth_rom/host_test.c $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-rc/sha3.c
	$(DBG_AUTH_HOST_SHA3) -DAUTH_ALG_SHA3 -o $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-label/host_test $(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-label/host_test.c test/dbg/auth_rom/sha3.c
	@for m in rc:'SHA3-256 known answer' label:'window.c 0x04 MAC word'; do d=$(DBG_AUTH_ROM_HOST_DIR)/sha3-mut-$${m%%:*}; \
	  if $$d/host_test > $$d/run.log 2>&1; then echo "SHA3 host mutant $${m%%:*} NOT detected"; exit 1; fi; \
	  grep -q "$${m#*:}" $$d/run.log || { echo "SHA3 host mutant $${m%%:*}: unexpected failure"; tail -1 $$d/run.log; exit 1; }; \
	  echo "detected SHA3 host mutant $${m%%:*}: $$(tail -1 $$d/run.log)"; done
	@echo "PASS auth ROM host model, algorithm 0x04: known answers, both ROMs reject the other algorithm, 2 mutants detected"

# Formal lemmas (plan 5.2) with Yosys + yosys-smtbmc/z3: BMC, k-induction and
# mutants per lemma; results in $(BUILD)/dbg/auth-formal/results.json. This
# is a separate, longer gate (A3); it is not part of dbg-functional-gates.
.PHONY: dbg-auth-formal-test
dbg-auth-formal-test:
	timeout 3600 python3 test/dbg/run_auth_formal.py --out $(BUILD)/dbg/auth-formal
	timeout 900 python3 test/dbg/check_auth_reset.py --self-test

# A4 (plan 3.5), what dbg-auth-sba-revoke-test leaves out: the same bench as
# a two-state Verilator build, with the instruction cache, and in the RVA23
# and vector configurations (the vector unit shares the data bus with the
# SBA); with the DDR crossbar as the responder (karu_ddr_xbar with its
# assertions, the beat held on either side of it, its local engines, and a
# stalled address phase); and through the JTAG transport (TAP, DTM and
# clock-domain crossing; an sbdata0 read in the crossing when debug_enable
# falls). Twelve configurations, four-state and two-state; every
# configuration must report the reference's scenarios and detect the three
# mutants of dbg-auth-sba-revoke-test. test/dbg/run_auth_revoke_ext.py;
# about four minutes.
DBG_AUTH_REVOKE_EXT ?= $(BUILD)/dbg/auth-revoke-ext
.PHONY: dbg-auth-revoke-ext-test
dbg-auth-revoke-ext-test: $(DBG_AUTH_CORE_DIR)/rom.hex
	timeout 2400 python3 test/dbg/run_auth_revoke_ext.py --out $(DBG_AUTH_REVOKE_EXT) --jobs $(DBG_JOBS) \
	  --rom-hex $(DBG_AUTH_CORE_DIR)/rom.hex --core-rtl '$(DBG_CORE_RTL)' --xbar-rtl '$(SBA_XBAR_RTL)' \
	  --jtag-rtl '$(KARUDBG_JTAG_SRCS)' > $(BUILD)/dbg/auth-revoke-ext.log 2>&1 || { tail -30 $(BUILD)/dbg/auth-revoke-ext.log; exit 1; }
	@grep '^PASS auth revocation extended' $(BUILD)/dbg/auth-revoke-ext.log

# The composition of the lemmas (plan 5.3; test/dbg/run_auth_compose.py):
# one model in which C9 and C10 hold together, each side's assumption about
# the other turned into an assertion; glue lemmas for what C1 to C10 left
# between them; and a report that matches every assume() of every lemma to
# the assertion or the platform assumption that discharges it, and fails on
# one that nothing discharges. One depends on the plan's wording: lemma C3
# gives its two runs the same authdata read data, status words included, and
# the script reads T1's third bullet from doc/debug-auth-plan.md to see that
# the plan gives them the same (it does since 2026-11-19; --tx-words-only
# checks the earlier wording, and fails). About 12 minutes; not in the gate.
DBG_AUTH_COMPOSE_FLAGS ?=
.PHONY: dbg-auth-compose-test
dbg-auth-compose-test:
	timeout 5400 python3 test/dbg/run_auth_compose.py --out $(BUILD)/dbg/auth-compose --jobs $(DBG_JOBS) $(DBG_AUTH_COMPOSE_FLAGS)

# Lemma C1 (plan 5.2), bypass freedom: Yosys flattens karudbg_top (KARU_DBG
# KARU_DBG_AUTH KARU_DBG_FULL KARU_NO_V); bit-level cones of influence from
# each protected element, stopped at the cuts, and the drivers of K2 and of
# the island's hart ports must match the script's allowlists exactly. Five
# RTL mutants must fail. Six parallel Yosys runs, about 80 s; inventory in
# $(BUILD)/dbg/auth-bypass/inventory.txt.
.PHONY: dbg-auth-bypass-test
dbg-auth-bypass-test:
	timeout 900 python3 test/dbg/check_auth_bypass.py --self-test --out $(BUILD)/dbg/auth-bypass
dbg-functional-gates: dbg-auth-bypass-test
# The same inventory as the VCU118 debug image is synthesised: its defines
# (H, the vector unit, Zkr and the instruction cache included) and the
# parameters its top gives karudbg_core (reset vector, external time, the
# hardware window limit at 2^31), with the two allowlist entries that H and
# Zkr add (IMAGE_DEFINES and IMAGE_PARAMS in the script). The island ROM is
# the simulation's SHA3 build with the public test key: the image's own
# holds the key and is not read. About three minutes, 2.5 GB.
.PHONY: dbg-auth-bypass-image-test
dbg-auth-bypass-image-test: $(DBG_AUTH_SHA3_DIR)/rom.hex
	timeout 1200 python3 test/dbg/check_auth_bypass.py --image --island-rom $(DBG_AUTH_SHA3_DIR)/rom.hex \
	  --out $(BUILD)/dbg/auth-bypass-image
dbg-functional-gates: dbg-auth-bypass-image-test
