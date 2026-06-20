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
#   make clean / distclean        scrub run artifacts / generation cache
#
# The `act`/`udb`/`bundle` env is sourced automatically per-recipe from
# env.sh (no need to source it in your shell first).

THIS_DIR  := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
KARU_ROOT  := $(realpath $(THIS_DIR)/../..)
ACT4_DIR  := $(realpath $(THIS_DIR)/../riscv-arch-test)
CONFIG    := $(THIS_DIR)/karu64-rv64gc/test_config.yaml
ELFS_DIR  := $(ACT4_DIR)/work/karu64-rv64gc/elfs
SIMV      := $(KARU_ROOT)/_build/Vhtif_fp/Vhtif_tb

# Slice selector: `make tests EXT=I` for the base-integer slice; blank = all
# extensions the config declares.
EXT  ?=
JOBS ?= $(shell nproc 2>/dev/null || echo 4)

.PHONY: help
help:
	@echo "test/act4-karu -- karu64 ACT4 targets:"
	@echo "  make tests [EXT=I] [JOBS=N]   generate self-checking ELFs (act + Sail)"
	@echo "  make run   [JOBS=N]           run generated ELFs on karu64 (Vhtif_fp TB)"
	@echo "  make all                      tests then run"
	@echo "  make clean                    remove _build/act-work run artifacts"
	@echo "  make distclean                also wipe the ACT4 generation cache"
	@echo ""
	@echo "  ELFs:   $(ELFS_DIR)"
	@echo "  config: $(CONFIG)"

.PHONY: tests
tests:
	. $(THIS_DIR)/env.sh && cd $(ACT4_DIR) && \
		act $(if $(EXT),-e $(EXT)) -j $(JOBS) $(CONFIG)

# The 4 MiB-RAM verilator TB doubles as the ACT4 runner harness (the ACT4
# ELFs are larger than the 128 KiB default RAM).
$(SIMV):
	$(MAKE) -C $(KARU_ROOT) _build/Vhtif_fp/Vhtif_tb

.PHONY: run
run: $(SIMV)
	@test -d "$(ELFS_DIR)" || { echo "no ELFs at $(ELFS_DIR) -- run 'make tests' first"; exit 2; }
	JOBS=$(JOBS) SIMV=$(SIMV) $(KARU_ROOT)/flow/run_act.sh -d $(ELFS_DIR)

.PHONY: all
all: tests run

.PHONY: clean
clean:
	rm -rf $(KARU_ROOT)/_build/act-work

.PHONY: distclean
distclean: clean
	rm -rf $(ACT4_DIR)/work/karu64-rv64gc
