# Milestone A: standalone propagation, stalls, cache/queue and firewall tests.
AXI_PROT_JOBS ?= 6
.PHONY: axi-prot-test axi-prot-debug-test
axi-prot-test:
	python3 test/dbg/axi_prot.py --build-dir $(BUILD)/dbg/axi-prot --jobs $(AXI_PROT_JOBS)
axi-prot-debug-test:
	python3 test/dbg/axi_prot.py --build-dir $(BUILD)/dbg/axi-prot-debug --jobs $(AXI_PROT_JOBS) --debug
