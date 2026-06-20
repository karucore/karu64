//	karu_mmu_test.S
//	Bare-metal U-mode / Sv39 / FENCE.I probe for the htif_tb harness.
//
//	Reproduces, in isolation and in seconds of sim, the failure class behind
//	"Linux userspace dies at PC=0 on the FPGA". Three independently-reported
//	subtests, each pinned to one hypothesis:
//
//	  ICOH  (exit 3) -- write code, FENCE.I, execute: proves the core IFU sees
//	                    freshly-stored instructions (core-level I/D coherence;
//	                    the external karu_sdram_cache is NOT in this harness).
//	  SRET  (exit 1) -- S-mode sret into a U-mode VA: proves xRET delivers the
//	                    user PC (sepc), not 0. If sret lands at 0 the first
//	                    U entry instruction-faults at epc=0 and we catch it.
//	  XLATE (exit 2) -- THE centerpiece. One virtual executable address X_VA is
//	                    mapped by two page tables (rootA, rootB) to two distinct
//	                    physical frames whose code writes a distinct marker
//	                    (0xA vs 0xB) into a0 before ecall. We enter U at X_VA
//	                    under rootA (clean, with sfence), then switch satp to
//	                    rootB WITHOUT sfence (exactly what Linux does on an ASID
//	                    context switch) and enter U at X_VA again. The captured
//	                    marker proves which physical frame was actually fetched:
//	                      0xB = correct (new translation used)
//	                      0xA = STALE translation (untagged TLB hit) -> the bug
//
//	exit 0 = all pass. The harness prints "[HTIF] exit <code>".
//
//	Section placement (see karu_mmu_test.ld) puts each table/frame at a fixed
//	4 KiB-aligned physical address; PTE values are pure constants computed from
//	those addresses. No stack is used (control transfer is register-based).

	//	fixed data slots (page 1)
	.equ	TOHOST,		0x80001000
	.equ	MARKER_VAR,	0x80001008	//	last U-mode a0 captured by m_trap
	.equ	M1_VAR,		0x80001010	//	entry-1 marker
	.equ	M2_VAR,		0x80001018	//	entry-2 marker
	.equ	MCAUSE_VAR,	0x80001020	//	fault diag
	.equ	MEPC_VAR,	0x80001028
	.equ	RESUME_VAR,	0x80001030	//	S-mode resume PC for m_trap
	.equ	ICOH1_VAR,	0x80001038
	.equ	ICOH2_VAR,	0x80001040
	.equ	M3_VAR,		0x80001048	//	bug-test (entry-4) marker

	//	page-table / frame physical addresses (must match karu_mmu_test.ld)
	.equ	L1A,		0x80004000
	.equ	L0A,		0x80005000
	.equ	L1B,		0x80006000
	.equ	L0B,		0x80007000
	.equ	FRAMEA,		0x80008000
	.equ	FRAMEB,		0x80009000

	//	the shared virtual executable address under test (region 0)
	.equ	X_VA,		0x00004000	//	vpn2=0 vpn1=0 vpn0=4

	//	Sv39 PTE flag bits
	.equ	PTE_V,		0x01
	.equ	PTE_R,		0x02
	.equ	PTE_W,		0x04
	.equ	PTE_X,		0x08
	.equ	PTE_U,		0x10
	.equ	PTE_A,		0x40
	.equ	PTE_D,		0x80

	//	PTE = (phys >> 12) << 10 | flags
	.equ	PTR_L1A,	((L1A   >> 12) << 10) | PTE_V
	.equ	PTR_L0A,	((L0A   >> 12) << 10) | PTE_V
	.equ	PTR_L1B,	((L1B   >> 12) << 10) | PTE_V
	.equ	PTR_L0B,	((L0B   >> 12) << 10) | PTE_V
	.equ	LEAF_A,		((FRAMEA>> 12) << 10) | PTE_V|PTE_R|PTE_X|PTE_U|PTE_A|PTE_D
	.equ	LEAF_B,		((FRAMEB>> 12) << 10) | PTE_V|PTE_R|PTE_X|PTE_U|PTE_A|PTE_D
	//	1 GiB identity leaf for region 2 (0x8000_0000), S rwx, U=0
	.equ	IDENT2,		((0x80000000 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_X|PTE_A|PTE_D

	//	satp = MODE_SV39(8) << 60 | ASID << 44 | root_ppn
	//	Two DIFFERENT ASIDs (1, 2): switching satp with a new ASID and no
	//	sfence.vma is exactly the Linux ASID context-switch case. A correct
	//	ASID-tagged TLB MUST then translate X_VA through the new root (frame B);
	//	karu's VPN-only TLB will wrongly hit the stale entry (frame A). With the
	//	same ASID, returning frame A would be architecturally legal, so distinct
	//	ASIDs are what make exit 2 a real proof of the untagged-TLB bug.
	.equ	SATPA,		(8 << 60) | (1 << 44) | (0x80002000 >> 12)
	.equ	SATPB,		(8 << 60) | (2 << 44) | (0x80003000 >> 12)

//	====================================================================
//	M-mode entry
//	====================================================================
	.section .text.boot, "ax"
	.globl	_start
_start:
	la	t0, m_trap
	csrw	mtvec, t0		//	all traps -> m_trap (no delegation)

	//	---- ICOH: write-then-FENCE.I-then-execute (M bare) ----
	la	s0, frameW
	jalr	ra, 0(s0)		//	run v1 -> a0 = 0x11
	li	t1, ICOH1_VAR
	sd	a0, 0(t1)

	//	overwrite frameW[0] (addi a0,x0,0x11) with addi a0,x0,0x22
	li	t2, 0x02200513		//	addi a0, x0, 0x22  (32-bit, see .option norvc)
	sw	t2, 0(s0)
	fence.i
	jalr	ra, 0(s0)		//	run v2 -> expect a0 = 0x22
	li	t1, ICOH2_VAR
	sd	a0, 0(t1)

	li	t1, 0x22
	bne	a0, t1, fail_icoh	//	stale instruction stream -> ICOH fail

	//	---- enter S-mode to run the paging subtests ----
	csrr	t0, mstatus
	li	t1, ~(3 << 11)
	and	t0, t0, t1		//	clear MPP
	li	t1, (1 << 11)
	or	t0, t0, t1		//	MPP = S
	csrw	mstatus, t0
	la	t0, driver_s
	csrw	mepc, t0
	mret

fail_icoh:
	li	t0, (3 << 1) | 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

//	====================================================================
//	M-mode trap handler. Expected cause: ecall-from-U (8) from the U test
//	frame -- capture a0, then resume the S-driver at RESUME_VAR in S-mode.
//	Any other cause (e.g. instruction fault at 0 from a bad sret) records a
//	0xFF sentinel + mcause/mepc so the driver can flag it.
//	====================================================================
	.balign 4
m_trap:
#ifdef DBG_TRAP_EXIT
	//	debug: surface the very first trap cause as the HTIF exit code
	csrr	t0, mcause
	slli	t0, t0, 1
	ori	t0, t0, 1
	li	t1, TOHOST
	sd	t0, 0(t1)
9:	j	9b
#endif
	csrr	t0, mcause
	li	t1, 8			//	ecall from U-mode
	bne	t0, t1, m_trap_fault
	li	t1, MARKER_VAR
	sd	a0, 0(t1)		//	a0 is the user register (no auto-save here)
	j	m_trap_resume
m_trap_fault:
	li	t1, MARKER_VAR
	li	t2, 0xFF
	sd	t2, 0(t1)
	csrr	t2, mcause
	li	t1, MCAUSE_VAR
	sd	t2, 0(t1)
	csrr	t2, mepc
	li	t1, MEPC_VAR
	sd	t2, 0(t1)
m_trap_resume:
	li	t1, RESUME_VAR
	ld	t0, 0(t1)
	csrw	mepc, t0
	csrr	t0, mstatus
	li	t1, ~(3 << 11)
	and	t0, t0, t1
	li	t1, (1 << 11)
	or	t0, t0, t1		//	MPP = S
	csrw	mstatus, t0
	mret

//	====================================================================
//	S-mode driver: SRET + XLATE subtests.
//
//	UENTER drops to U-mode at X_VA via sret, recording where to resume the
//	S-driver afterwards (m_trap mret's back there). RECMARK copies the a0 the
//	handler captured into a result slot.
//	====================================================================
	.macro	UENTER resume_label
	la	t0, \resume_label
	li	t1, RESUME_VAR
	sd	t0, 0(t1)
	li	t0, X_VA
	csrw	sepc, t0
	li	t1, 0x100		//	clear sstatus.SPP -> return to U
	csrc	sstatus, t1
	sret
	.endm

	.macro	RECMARK var
	li	t0, MARKER_VAR
	ld	t0, 0(t0)
	li	t1, \var
	sd	t0, 0(t1)
	.endm

	.balign 4
driver_s:
	//	ENTRY 1: rootA + sfence -> expect 0xA.  Proves sret delivers X_VA (not
	//	0) and frameA is reachable; leaves the TLB primed with X_VA -> frameA.
	li	t0, SATPA
	csrw	satp, t0
	sfence.vma
	UENTER	resume1
resume1:
	RECMARK	M1_VAR

	//	ENTRY 2 (POSITIVE CONTROL): rootB + sfence -> expect 0xB.  Proves
	//	rootB/frameB is independently reachable when the switch is fenced, so a
	//	later frameA result can only be a stale-TLB bug, not a broken rootB.
	li	t0, SATPB
	csrw	satp, t0
	sfence.vma
	UENTER	resume2
resume2:
	RECMARK	M2_VAR

	//	ENTRY 3: rootA + sfence -> re-prime TLB with X_VA -> frameA (clean).
	li	t0, SATPA
	csrw	satp, t0
	sfence.vma
	UENTER	resume3
resume3:

	//	ENTRY 4 (THE BUG TEST): rootB, NO sfence -> expect 0xB on an ASID-tagged
	//	TLB; a VPN-only TLB stale-hits the entry-3 mapping and runs frameA.
	li	t0, SATPB
	csrw	satp, t0
	//	deliberately NO sfence.vma here
	UENTER	resume4
resume4:
	RECMARK	M3_VAR

	//	---- evaluate ----
	li	t0, M1_VAR
	ld	t0, 0(t0)
	li	t1, 0xA
	bne	t0, t1, fail_sret	//	entry 1 did not run frameA via sret -> SRET/fetch

	li	t0, M2_VAR
	ld	t0, 0(t0)
	li	t1, 0xB
	bne	t0, t1, fail_posctl	//	positive control failed -> rootB/frameB unreachable

	li	t0, M3_VAR
	ld	t0, 0(t0)
	li	t1, 0xB
	beq	t0, t1, all_pass	//	new ASID translation honoured -> good (fixed)
	j	fail_xlate		//	0xA (stale) or other -> untagged-TLB bug

all_pass:
	li	t0, 1			//	exit 0
	j	write_tohost
fail_sret:
	li	t0, (1 << 1) | 1	//	exit 1
	j	write_tohost
fail_xlate:
	li	t0, (2 << 1) | 1	//	exit 2
	j	write_tohost
fail_posctl:
	li	t0, (4 << 1) | 1	//	exit 4
write_tohost:
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

//	====================================================================
//	U-mode test frames. Position-independent (immediate + ecall only) so
//	they execute correctly at X_VA regardless of physical placement.
//	====================================================================
	.section .frameA, "ax"
	.globl	frameA
frameA:
	li	a0, 0xA
	ecall
1:	j	1b

	.section .frameB, "ax"
	.globl	frameB
frameB:
	li	a0, 0xB
	ecall
1:	j	1b

//	====================================================================
//	ICOH target frame. Forced 32-bit so the runtime patch (sw) replaces a
//	whole instruction word. v1: a0=0x11; patched in place to a0=0x22.
//	====================================================================
	.section .frameW, "ax"
	.globl	frameW
frameW:
	.option push
	.option norvc
	addi	a0, x0, 0x11
	ret
	.option pop

//	====================================================================
//	Sv39 page tables. Each table is its own section placed by the linker at
//	a 4 KiB boundary; entries are emitted explicitly (unlisted entries left
//	unmapped -- the hardware walker never reads them for our test VAs).
//	rootA[0] -> L1A -> L0A[4] -> frameA (U,X)   rootA[2] = identity region 2
//	rootB[0] -> L1B -> L0B[4] -> frameB (U,X)   rootB[2] = identity region 2
//	====================================================================
	.section .rootA, "a"
	.quad	PTR_L1A			//	[0]
	.quad	0			//	[1]
	.quad	IDENT2			//	[2]

	.section .rootB, "a"
	.quad	PTR_L1B			//	[0]
	.quad	0			//	[1]
	.quad	IDENT2			//	[2]

	.section .l1a, "a"
	.quad	PTR_L0A			//	[0]

	.section .l0a, "a"
	.rept	4
	.quad	0			//	[0..3]
	.endr
	.quad	LEAF_A			//	[4]

	.section .l1b, "a"
	.quad	PTR_L0B			//	[0]

	.section .l0b, "a"
	.rept	4
	.quad	0			//	[0..3]
	.endr
	.quad	LEAF_B			//	[4]
