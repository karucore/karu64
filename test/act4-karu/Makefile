# test/act4-karu/Makefile
#
# Drive the ACT4 (RISC-V Architectural Certification Test, framework v4)
# flow against karu64. ACT4 replaces the deprecated riscof: the Sail model
# bakes golden results into self-checking ELFs ahead of time, and the DUT
# just runs them. See ../../doc/architecture.md and ../riscv-arch-test/README.md.
#
#   make tests [EXT=I] [JOBS=N]   generate self-checking ELFs via `act`
#   make run   [JOBS=N]           run the generated ELFs on karu64
#   make all                      tests + run
#   make apply-patches            apply maintained ACT4 dependency fixes
#   make clean / distclean        scrub run artifacts / generation cache
#
# Activate the ACT4 tool environment before invoking make. Tool lookup uses
# the caller's PATH; compiler and reference-model names are in test_config.yaml.

THIS_DIR  := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
KARU_ROOT  := $(realpath $(THIS_DIR)/../..)
ACT4_DIR  := $(realpath $(THIS_DIR)/../riscv-arch-test)
CONFIG_NAME ?= karu64-rv64gc
PROFILE_CONFIGS := karu64-rva23s64 karu64-rva23s64-smcntrpmf
ifeq ($(filter $(CONFIG_NAME),karu64-rv64gc karu64-sv39 karu64-h $(PROFILE_CONFIGS)),)
$(error CONFIG_NAME must be karu64-rv64gc, karu64-sv39, karu64-h or one of $(PROFILE_CONFIGS))
endif
GENERATED_CONFIG := $(KARU_ROOT)/_build/act-config/$(CONFIG_NAME)
ifneq ($(CONFIG_NAME),karu64-rv64gc)
CONFIG    := $(GENERATED_CONFIG)/test_config.yaml
RUN_WORK  := $(KARU_ROOT)/_build/act-work-$(patsubst karu64-%,%,$(CONFIG_NAME))
else
CONFIG    := $(THIS_DIR)/karu64-rv64gc/test_config.yaml
RUN_WORK  := $(KARU_ROOT)/_build/act-work
endif
ELFS_DIR  := $(ACT4_DIR)/work/$(CONFIG_NAME)/elfs
ifeq ($(CONFIG_NAME),karu64-rva23s64-smcntrpmf)
SIMV      := $(KARU_ROOT)/_build/Vhtif_rva23s64_smcntrpmf/Vhtif_tb
else ifeq ($(CONFIG_NAME),karu64-rva23s64)
SIMV      := $(KARU_ROOT)/_build/Vhtif_rva23s64/Vhtif_tb
else ifeq ($(CONFIG_NAME),karu64-h)
SIMV      := $(KARU_ROOT)/_build/Vhtif_h/Vhtif_tb
else
SIMV      := $(KARU_ROOT)/_build/Vhtif_fp/Vhtif_tb
endif

# Slice selector: `make tests EXT=I` for the base-integer slice; blank = all
# extensions the config declares.
EXT  ?=
JOBS ?=
ACT_FLAGS ?=
PYTHON ?= python3
REF_MODEL_EXE ?=
ifneq ($(filter $(CONFIG_NAME),$(PROFILE_CONFIGS)),)
H_UDB_ROOT ?= $(KARU_ROOT)/_build/udb-$(patsubst karu64-%,%,$(CONFIG_NAME))-0.1.16
else
H_UDB_ROOT ?= $(KARU_ROOT)/_build/udb-h-0.1.16
endif
ifneq ($(filter $(CONFIG_NAME),karu64-h $(PROFILE_CONFIGS)),)
UDB_ENV = UDB_ROOT=$(H_UDB_ROOT)
else
UDB_ENV =
endif

.PHONY: help
help:
	@echo "test/act4-karu -- karu64 ACT4 targets:"
	@echo "  make tests [EXT=I] [JOBS=N]   generate self-checking ELFs (act + Sail)"
	@echo "  make run   [JOBS=N]           run generated ELFs on the selected karu64 model"
	@echo "  make all                      tests then run"
	@echo "  make config                   materialize/validate the selected Sail config"
	@echo "  make apply-patches            apply maintained ACT4 dependency fixes (idempotent)"
	@echo "  make test-h-capability        check conditional H CSR test masks (no Sail run)"
	@echo "  make test-h-trap-harness      check H trap layout/CSR bytes (after H config generation)"
	@echo "  make test-priv-trap-lifecycle check privilege entry, cleanup and signature capacity"
	@echo "  make test-priv-epc-origin     check nominal trap-origin root selection"
	@echo "  make test-priv-irq-wfi        check WFI-independent interrupt generators"
	@echo "  make test-profile-config     check isolated RVA23S64 config composition"
	@echo "  make test-profile-csr PROFILE_CSR_FLAGS='--sail ... --config ... --simv ... --output ...'"
	@echo "  make clean                    remove selected config's run artifacts"
	@echo "  make distclean                also wipe selected ACT4 generation cache"
	@echo "  CONFIG_NAME=karu64-sv39        separate S/U Sv39 privileged-1.13 baseline"
	@echo "  CONFIG_NAME=karu64-h           separate opt-in H/VS/G verification target"
	@echo "  CONFIG_NAME=karu64-rva23s64    opt-in profile build reference (Sscofpmf, no Smcntrpmf)"
	@echo "  CONFIG_NAME=karu64-rva23s64-smcntrpmf  separate optional fixed-counter filtering reference"
	@echo ""
	@echo "  ELFs:   $(ELFS_DIR)"
	@echo "  config: $(CONFIG)"

.PHONY: apply-patches
apply-patches:
	@set -eu; \
	for patch_file in "$(THIS_DIR)/patches/sm-counter-wrap.patch" "$(THIS_DIR)/patches/ref-model-version.patch" "$(THIS_DIR)/patches/h-capability.patch" "$(THIS_DIR)/patches/h-trap-harness.patch" "$(THIS_DIR)/patches/priv-trap-lifecycle.patch" "$(THIS_DIR)/patches/priv-epc-origin.patch" "$(THIS_DIR)/patches/priv-irq-wfi.patch" "$(THIS_DIR)/patches/udb-geilen-zero.patch"; do \
	if patch --batch --forward --fuzz=0 -p1 --dry-run -d "$(ACT4_DIR)" -i "$$patch_file" >/dev/null 2>&1; then \
		patch --batch --forward --fuzz=0 --no-backup-if-mismatch -p1 \
			-d "$(ACT4_DIR)" -i "$$patch_file"; \
	elif patch --batch --forward --reverse --fuzz=0 -p1 --dry-run \
		-d "$(ACT4_DIR)" -i "$$patch_file" >/dev/null 2>&1; then \
		echo "ACT4 patch already applied: $$patch_file"; \
	else \
		echo "ACT4 source mismatch; patch not applied: $$patch_file" >&2; \
		exit 1; \
	fi; \
	done

.PHONY: test-h-capability test-h-trap-harness test-priv-trap-lifecycle test-priv-epc-origin test-priv-irq-wfi test-profile-config test-profile-csr
test-h-capability:
	$(PYTHON) $(THIS_DIR)/test_h_capability.py
test-h-trap-harness:
	$(PYTHON) $(THIS_DIR)/test_h_trap_harness.py
test-priv-trap-lifecycle:
	$(PYTHON) $(THIS_DIR)/test_priv_trap_lifecycle.py
test-priv-epc-origin:
	$(PYTHON) $(THIS_DIR)/test_priv_epc_origin.py
test-priv-irq-wfi:
	$(PYTHON) $(THIS_DIR)/test_priv_irq_wfi.py
test-profile-config:
	$(PYTHON) $(THIS_DIR)/karu64-rva23s64/test_config.py
test-profile-csr:
	$(PYTHON) $(THIS_DIR)/karu64-rva23s64/check_csr.py $(PROFILE_CSR_FLAGS)

.PHONY: prepare-config config
prepare-config:
ifneq ($(filter $(CONFIG_NAME),karu64-h $(PROFILE_CONFIGS)),)
	H_UDB_ROOT=$(H_UDB_ROOT) bash $(THIS_DIR)/prepare_udb_h.sh
endif
ifneq ($(CONFIG_NAME),karu64-rv64gc)
	$(PYTHON) $(THIS_DIR)/generate_config.py --configuration $(CONFIG_NAME) --output-dir $(GENERATED_CONFIG) \
		$(if $(REF_MODEL_EXE),--ref-model-exe $(REF_MODEL_EXE))
endif

config: prepare-config
	$(if $(REF_MODEL_EXE),$(REF_MODEL_EXE),sail_riscv_sim) --config $(dir $(CONFIG))sail.json --validate-config

.PHONY: tests
tests: prepare-config
	cd $(ACT4_DIR) && \
		$(UDB_ENV) act $(if $(EXT),-e $(EXT)) $(if $(JOBS),-j $(JOBS)) $(ACT_FLAGS) $(CONFIG)

# The 4 MiB-RAM verilator TB doubles as the ACT4 runner harness (the ACT4
# ELFs are larger than the 128 KiB default RAM).
$(SIMV):
ifeq ($(CONFIG_NAME),karu64-rva23s64-smcntrpmf)
	$(MAKE) -C $(KARU_ROOT) rva23-sim VERI_RVA23_DIR=$(patsubst %/,%,$(dir $(SIMV))) VFLAGS='$(VFLAGS) -DKARU_SMCNTRPMF'
else ifeq ($(CONFIG_NAME),karu64-rva23s64)
	$(MAKE) -C $(KARU_ROOT) rva23-sim VERI_RVA23_DIR=$(patsubst %/,%,$(dir $(SIMV)))
else ifeq ($(CONFIG_NAME),karu64-h)
	$(MAKE) -C $(KARU_ROOT) h-sim VERI_H_DIR=$(patsubst %/,%,$(dir $(SIMV)))
else
	$(MAKE) -C $(KARU_ROOT) _build/Vhtif_fp/Vhtif_tb
endif

.PHONY: run
run: $(SIMV)
	@test -d "$(ELFS_DIR)" || { echo "no ELFs at $(ELFS_DIR) -- run 'make tests' first"; exit 2; }
	$(if $(JOBS),JOBS=$(JOBS)) WORKDIR=$(RUN_WORK) SIMV=$(SIMV) $(KARU_ROOT)/flow/run_act.sh -d $(ELFS_DIR)

.PHONY: all
all:
	$(MAKE) tests
	$(MAKE) run

.PHONY: clean
clean:
	rm -rf "$(RUN_WORK)"

.PHONY: distclean
distclean: clean
	rm -rf "$(ACT4_DIR)/work/$(CONFIG_NAME)"
