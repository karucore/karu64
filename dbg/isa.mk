# Ordinary ISA tests run with debug idle; they are not debug compliance tests.
DBG_ISA_DIR ?= $(BUILD)/Vhtif_dbg_full
DBG_ISA_FLAGS ?= -Irtl -Idbg -DKARU_DBG -DKARU_DBG_FULL -DKARU_ICACHE \
 -DKARU_ZVK -DKARU_KECCAK -DKARU_M_MUL_CYCLES=4 -DKARU_M_DIV_CYCLES=64 \
 -DKARU_V_MUL_CYCLES=16 -DKARU_V_DIV_CYCLES=64 -DKARU_V_LANE_PIPE \
 -DKARU_V_CWB_STAGE -DKARU_SMCNTRPMF -DKARU_SSCOFPMF
DBG_ISA_EFFECTIVE_FLAGS = $(DBG_ISA_FLAGS) -DKARU_RVA23S64 -DHTIF_TB_CLINT -DHTIF_TB_EXTIRQ
DBG_ISA_ELF_ROOT ?= test/riscv-arch-test/work/karu64-rva23s64-smcntrpmf/elfs
DBG_ISA_OUT ?= $(BUILD)/dbg/isa-replay
DBG_ISA_EXT ?= $(EXT)
DBG_ISA_JOBS ?= 4
DBG_ISA_TIMEOUT ?= 120
DBG_ISA_MAX_CYCLES ?= 20000000
DBG_ISA_ARGS = --sim $(DBG_ISA_DIR)/Vhtif_tb --elf-root $(DBG_ISA_ELF_ROOT) \
 --out $(DBG_ISA_OUT) --ext '$(DBG_ISA_EXT)' --jobs $(DBG_ISA_JOBS) \
 --timeout $(DBG_ISA_TIMEOUT) --max-cycles $(DBG_ISA_MAX_CYCLES) \
 --flags='$(DBG_ISA_EFFECTIVE_FLAGS)' --xchain '$(XCHAIN)'

.PHONY: dbg-isa-flags-force dbg-isa-sim dbg-isa-manifest dbg-isa-replay dbg-isa-runner-test
$(DBG_ISA_DIR)/debug-flags.txt: dbg-isa-flags-force
	@mkdir -p $(dir $@)
	@printf '%s\n' '$(DBG_ISA_EFFECTIVE_FLAGS)' > $@.tmp
	@if cmp -s $@ $@.tmp; then rm $@.tmp; else mv $@.tmp $@; fi

# Add flag tracking to the ordinary HTIF recipe, including recursive makes.
$(DBG_ISA_DIR)/Vhtif_tb.mk: $(DBG_ISA_DIR)/debug-flags.txt dbg/isa.mk dbg/karudbg_cfg.vh

dbg-isa-sim:
	python3 test/dbg/build_isa.py --dir $(DBG_ISA_DIR) --jobs 4 --flags='$(DBG_ISA_FLAGS)'

dbg-isa-runner-test:
	python3 -m unittest discover -s test/dbg -p test_isa_replay.py
	python3 -m unittest discover -s test/dbg -p test_htif_consumption.py
	python3 -m unittest discover -s test/dbg -p test_idle_cycles.py

# Inventory/hash only: no simulation, reference generation or dependency edits.
dbg-isa-manifest:
	python3 test/dbg/replay_isa.py $(DBG_ISA_ARGS) --dry-run

dbg-isa-replay: dbg-isa-sim
	python3 test/dbg/replay_isa.py $(DBG_ISA_ARGS)

DBG_ORDINARY_NAMES = keccak_subj zvk_subj zvbb_subj vstart_subj vresv_subj \
 vperm_subj fma_hazard_subj karu_h_test karu_hfence_test karu_hmem_hfence_test \
 karu_hvm_test karu_hpbmt_test karu_htimer_test karu_hcontext_test \
 karu_hcontext_keccak_test karu_hpreempt_test
DBG_ORDINARY_ELFS = $(addprefix $(BUILD)/,$(addsuffix .elf,$(DBG_ORDINARY_NAMES)))
.PHONY: dbg-ordinary-isa-test
dbg-ordinary-isa-test: dbg-isa-sim $(DBG_ORDINARY_ELFS)
	python3 test/dbg/replay_isa.py --ordinary --sim $(DBG_ISA_DIR)/Vhtif_tb \
	  --elf-root $(BUILD) $(foreach elf,$(DBG_ORDINARY_ELFS),--elf-file $(elf)) \
	  --out $(BUILD)/dbg/ordinary-isa --jobs $(DBG_ISA_JOBS) --timeout $(DBG_ISA_TIMEOUT) \
	  --max-cycles $(DBG_ISA_MAX_CYCLES) --flags='$(DBG_ISA_EFFECTIVE_FLAGS)' --xchain '$(XCHAIN)'
