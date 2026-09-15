//	karu_mmu_test.S
//	Bare-metal U-mode / Sv39 / Svade / Svnapot / Svpbmt / Svinval regression.
//
//	Reproduces, in isolation and in seconds of sim, the failure class behind
//	"Linux userspace dies at PC=0 on the FPGA". Four independently-reported
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
//	  SVADE (exit 0x20 + case) -- precise fetch/load/store A/D page faults,
//	                    unchanged PTE/data, load-filled D=0 TLB rejection,
//	                    software repair with Svinval, non-leaf U/A/D,
//	                    MPRV/SUM/MXR, lower-privilege xRET behavior, and CBO
//	                    management permissions/page-tail block boundaries;
//	                    Svnapot fetch/load/store across all sixteen subpages,
//	                    A/D faults and reserved size encodings; Svpbmt gates,
//	                    attributes, permissions, scalar widths/atomics and
//	                    fenced cacheability transitions/split-page accesses;
//	                    younger fetch-fault deferral behind older scalar loads
//	                    and stores, including second-page data-fault priority.
//
//	exit 0 = all pass. The harness prints "[HTIF] exit <code>".
//
//	Section placement (see karu_mmu_test.ld) puts each table/frame at a fixed
//	4 KiB-aligned physical address; PTE values are pure constants computed from
//	those addresses. No stack is used (control transfer is register-based).

	//	fixed data slots (page 1)
	.equ	TOHOST,		0x80001000
	.globl	tohost, fromhost
	.set	tohost, TOHOST
	.set	fromhost, TOHOST + 0x58
	.equ	MARKER_VAR,	0x80001008	//	last U-mode a0 captured by m_trap
	.equ	M1_VAR,		0x80001010	//	entry-1 marker
	.equ	M2_VAR,		0x80001018	//	entry-2 marker
	.equ	MCAUSE_VAR,	0x80001020	//	fault diag
	.equ	MEPC_VAR,	0x80001028
	.equ	RESUME_VAR,	0x80001030	//	S-mode resume PC for m_trap
	.equ	ICOH1_VAR,	0x80001038
	.equ	ICOH2_VAR,	0x80001040
	.equ	M3_VAR,		0x80001048	//	bug-test (entry-4) marker
	.equ	ORDER_PHASE,	0x80001180	// optional +ifu_faultcheck overlap observer

	//	page-table / frame physical addresses (must match karu_mmu_test.ld)
	.equ	L1A,		0x80004000
	.equ	L0A,		0x80005000
	.equ	L1B,		0x80006000
	.equ	L0B,		0x80007000
	.equ	FRAMEA,		0x80008000
	.equ	FRAMEB,		0x80009000

	//	the shared virtual executable address under test (region 0)
	.equ	X_VA,		0x00004000	//	vpn2=0 vpn1=0 vpn0=4
	.equ	NAPOT_VA,	0x00010000	//	vpn0=16..31, naturally aligned 64 KiB
	.equ	NAPOT_PA,	0x80010000	//	runtime test frames, above the test code

	//	Sv39 PTE flag bits
	.equ	PTE_V,		0x01
	.equ	PTE_R,		0x02
	.equ	PTE_W,		0x04
	.equ	PTE_X,		0x08
	.equ	PTE_U,		0x10
	.equ	PTE_A,		0x40
	.equ	PTE_D,		0x80
	.equ	PTE_N,		0x8000000000000000
	.equ	PTE_NC,		0x2000000000000000
	.equ	PTE_IO,		0x4000000000000000
	.equ	PBMTE,		0x4000000000000000
	.equ	NAPOT_LEAF,	(((NAPOT_PA + 0x8000) >> 12) << 10) | PTE_N

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
	jal	ra, svade_checks

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
//	Svade checks reuse rootA and frameA before the U/S context-switch tests.
//	MPRV supplies S-mode data permissions while the driver/handler remain
//	bare M-mode. The independent walker bench tests all page sizes, the
//	permission truth table and outstanding AXI/flush phases.
//	====================================================================
	.section .text.svade, "ax"
	// Changing between the bare physical alias and a PBMT alias requires
	// this sequence even if the physical address and permissions agree.
	// The caller is bare M-mode; the block address is a physical register.
	.macro	PBMT_SYNC addr=s8
	fence	iorw, iorw
	.insn	i 0x0f, 2, x0, \addr, 2 // cbo.flush
	fence	iorw, iorw
	.endm

	.macro	SET_PTE addr, value
	li	t0, \addr
	li	t1, \value
	sd	t1, 0(t0)
	sfence.vma
	.endm

	.macro	CHECK_DATA op, cause, prv=1, sum=0, mxr=0, address=(X_VA + 0x100), physical=(FRAMEA + 0x100), pbmt=0, value=0x1122334455667788
	addi	s6, s6, 1
	li	s2, \cause
	.ifnc \address,s3
	li	s3, \address
	.endif
	la	s4, .Ldata_resume\@
	la	s7, .Ldata_insn\@
	li	s5, 0
	.ifnc \physical,s8
	li	s8, \physical
	.endif
	ld	s9, 0(s8)		//	physical memory before the access
	.if \pbmt
	PBMT_SYNC			// includes the actual warm physical read above
	.endif
	li	t2, \value
	li	t0, (3 << 11) | (1 << 18) | (1 << 19)
	csrc	mstatus, t0
	li	t0, (1 << 17) | (\prv << 11) | (\sum << 18) | (\mxr << 19)
	csrs	mstatus, t0		//	MPRV uses MPP/SUM/MXR for data only
.Ldata_insn\@:
	.option push
	.option norvc
	\op	t2, 0(s3)
	.option pop
.Ldata_resume\@:
	li	t0, (1 << 17)
	csrc	mstatus, t0
	.if \pbmt
	PBMT_SYNC
	.endif
	.if \cause
	li	t0, 1
	bne	s5, t0, fail_svade
	.ifc \op,ld
	li	t0, \value
	bne	t2, t0, fail_svade	//	faulting load preserves its destination
	.endif
	ld	t0, 0(s8)
	bne	t0, s9, fail_svade	//	faulting access preserves memory
	.else
	bnez	s5, fail_svade
	.ifc \op,ld
	bne	t2, s9, fail_svade
	.else
	ld	t0, 0(s8)
	bne	t0, t2, fail_svade
	.endif
	.endif
	.endm

	//	CBO selectors: 0=INVAL, 1=CLEAN, 2=FLUSH, 4=ZERO. MPRV selects
	//	the S-mode translation; instruction enable is M-mode (always allowed).
	//	Check the whole 64-byte block plus both adjacent doubleword canaries.
	.macro	CHECK_CBO selector, cause, address=(X_VA + 0x100), mxr=0
	addi	s6, s6, 1
	li	s2, \cause
	li	s3, \address
	la	s4, .Lcbo_resume\@
	la	s7, .Lcbo_insn\@
	li	s5, 0
	li	s8, FRAMEA + ((\address - X_VA) & ~63)
	ld	a3, -8(s8)
	ld	a4, 64(s8)
	li	a5, 0x1122334455667788
	mv	t0, s8
	addi	t1, s8, 64
.Lcbo_fill\@:
	sd	a5, 0(t0)
	addi	t0, t0, 8
	bne	t0, t1, .Lcbo_fill\@
	.if \selector == 0
	//	Make the data clean before INVAL: otherwise a write-back cache may
	//	legally discard the newly written dirty bytes. Bare M-mode uses the
	//	physical address here, so this does not prime the tested translation.
	.insn	i 0x0f, 2, x0, s8, 1
	.endif
	li	t0, L0A + 4*8
	ld	a2, 0(t0)		//	the CBO must never modify its PTE
	li	t0, (3 << 11) | (1 << 18) | (1 << 19)
	csrc	mstatus, t0
	li	t0, (1 << 17) | (1 << 11) | (\mxr << 19)
	csrs	mstatus, t0
.Lcbo_insn\@:
	.insn	i 0x0f, 2, x0, s3, \selector
.Lcbo_resume\@:
	li	t0, (1 << 17)
	csrc	mstatus, t0
	.if \cause
	li	t0, 1
	bne	s5, t0, fail_svade
	.else
	bnez	s5, fail_svade
	.if \selector == 4
	li	a5, 0			//	only successful CBO.ZERO changes bytes
	.endif
	.endif
	li	t0, L0A + 4*8
	ld	t0, 0(t0)
	bne	t0, a2, fail_svade
	mv	t0, s8
	addi	t1, s8, 64
.Lcbo_check\@:
	ld	t2, 0(t0)
	bne	t2, a5, fail_svade
	addi	t0, t0, 8
	bne	t0, t1, .Lcbo_check\@
	ld	t0, -8(s8)
	bne	t0, a3, fail_svade
	ld	t0, 64(s8)
	bne	t0, a4, fail_svade
	.endm

	.macro	CHECK_POINTER addr, value
	SET_PTE \addr, \value
	CHECK_DATA ld, 13
	li	t0, \addr
	ld	t0, 0(t0)
	li	t1, \value
	bne	t0, t1, fail_svade
	.endm

	.balign 4
svade_checks:
	mv	s0, ra
	li	s6, 0
	li	s10, 0
	la	t0, svade_trap
	csrw	mtvec, t0
	li	t0, SATPA
	csrw	satp, t0
	li	t0, (1 << 61)
	csrc	0x30a, t0		//	Svade, including on a Svadu-capable reference
	li	t0, FRAMEA + 0x100
	li	t1, 0x8877665544332211
	sd	t1, 0(t0)

	SET_PTE L0A + 4*8, (LEAF_A & ~(PTE_U|PTE_A|PTE_D)) | PTE_W
	CHECK_DATA ld, 13		//	A=0,D=0
	CHECK_DATA sd, 15
	SET_PTE L0A + 4*8, (LEAF_A & ~(PTE_U|PTE_A)) | PTE_W
	CHECK_DATA ld, 13		//	A=0,D=1
	CHECK_DATA sd, 15
	SET_PTE L0A + 4*8, (LEAF_A & ~(PTE_U|PTE_D)) | PTE_W
	CHECK_DATA ld, 0		//	A=1,D=0: fill DTLB by load
	CHECK_DATA sd, 15		//	D must be checked on that TLB hit
	li	t0, L0A + 4*8
	ld	t1, 0(t0)
	li	t2, (LEAF_A & ~(PTE_U|PTE_D)) | PTE_W
	bne	t1, t2, fail_svade	//	PTE not silently dirtied

	//	Repair D in memory, then order/invalidate using nonzero VA/ASID
	//	operands. The following store must observe the repaired PTE; leaving
	//	the old TLB or page-walk-cache entry live would still fault.
	ori	t1, t1, PTE_D
	sd	t1, 0(t0)
	.word	0x18000073		//	sfence.w.inval
	li	t0, X_VA
	li	t1, 1			//	SATPA.ASID
	.insn	r 0x73, 0, 0x0b, x0, t0, t1 // sinval.vma t0,t1
	.word	0x18100073		//	sfence.inval.ir
	CHECK_DATA sd, 0
	CHECK_DATA ld, 0

	//	MPRV uses U permissions for MPP=U; SUM applies only to S accesses
	//	to U pages, and MXR controls reads of execute-only pages immediately.
	SET_PTE L0A + 4*8, LEAF_A | PTE_W
	CHECK_DATA ld, 0, 0
	CHECK_DATA sd, 0, 0
	CHECK_DATA ld, 13, 1, 0
	CHECK_DATA sd, 15, 1, 0
	CHECK_DATA ld, 0, 1, 1
	CHECK_DATA sd, 0, 1, 1
	SET_PTE L0A + 4*8, (LEAF_A & ~PTE_U) | PTE_W
	CHECK_DATA ld, 13, 0
	CHECK_DATA sd, 15, 0
	SET_PTE L0A + 4*8, LEAF_A & ~PTE_R
	CHECK_DATA ld, 13, 0, 0, 0
	CHECK_DATA ld, 0, 0, 0, 1
	SET_PTE L0A + 4*8, LEAF_A & ~(PTE_R|PTE_U)
	CHECK_DATA ld, 13, 1, 0, 0
	CHECK_DATA ld, 0, 1, 0, 1
	SET_PTE L0A + 4*8, (LEAF_A & ~PTE_U) | PTE_W

	//	All three management operations accept readable A=1,D=0 mappings.
	//	Exercise each with a cold translation and then the resulting TLB hit.
	.irp	selector, 0, 1, 2
	SET_PTE L0A + 4*8, LEAF_A & ~(PTE_U|PTE_X|PTE_D)
	CHECK_CBO \selector, 0
	CHECK_CBO \selector, 0
	SET_PTE L0A + 4*8, LEAF_A & ~(PTE_U|PTE_X|PTE_A|PTE_D)
	CHECK_CBO \selector, 15	//	A remains required; D remains ignored
	SET_PTE L0A + 4*8, LEAF_A & ~(PTE_U|PTE_R|PTE_D)
	CHECK_CBO \selector, 0, (X_VA + 0x100), 1
	CHECK_CBO \selector, 0, (X_VA + 0x100), 1 // X-only is readable with MXR
	.endr

	//	CBO.ZERO remains a real store: D=0 faults even if a management
	//	operation has already filled a translation for the writable page.
	SET_PTE L0A + 4*8, (LEAF_A & ~(PTE_U|PTE_D)) | PTE_W
	CHECK_CBO 1, 0
	CHECK_CBO 4, 15

	//	A CBO naming the final byte of a page still operates entirely on
	//	that page's last 64-byte block, never an 8-byte access spanning into
	//	the unmapped next virtual page. Include cold and TLB-hit paths.
	SET_PTE L0A + 5*8, 0
	.irp	selector, 0, 1, 2, 4
	SET_PTE L0A + 4*8, (LEAF_A & ~PTE_U) | PTE_W
	CHECK_CBO \selector, 0, (X_VA + 0xfff)
	CHECK_CBO \selector, 0, (X_VA + 0xfff)
	.endr
	SET_PTE L0A + 4*8, (LEAF_A & ~PTE_U) | PTE_W

	//	Non-leaf U/A/D are reserved at both pointer levels. Restore each
	//	pointer before testing the other; the M-mode instruction path is bare.
	CHECK_POINTER 0x80002000, PTR_L1A | PTE_U
	CHECK_POINTER 0x80002000, PTR_L1A | PTE_A
	CHECK_POINTER 0x80002000, PTR_L1A | PTE_D
	SET_PTE 0x80002000, PTR_L1A
	CHECK_POINTER L1A, PTR_L0A | PTE_U
	CHECK_POINTER L1A, PTR_L0A | PTE_A
	CHECK_POINTER L1A, PTR_L0A | PTE_D
	SET_PTE L1A, PTR_L0A

	//	Instruction page fault must report the faulting virtual PC, not the
	//	PTE address. Both D values are irrelevant when A is clear. MPRV
	//	must be cleared by either xRET when returning below M mode.
	SET_PTE L0A + 4*8, LEAF_A & ~(PTE_A|PTE_D)
	li	a1, 0			//	MRET to U
	jal	ra, check_fetch_a0
	SET_PTE L0A + 4*8, LEAF_A & ~PTE_A
	jal	ra, check_fetch_a0
	li	a1, 1			//	SRET from M to U
	jal	ra, check_fetch_a0
	SET_PTE L0A + 4*8, LEAF_A
	li	a1, 0
	jal	ra, check_return_s	//	MRET to S
	li	a1, 1
	jal	ra, check_return_s	//	SRET from M to S
	jal	ra, napot_checks
	jal	ra, pbmt_checks
	jal	ra, fault_order_checks
	li	t0, (1 << 18) | (1 << 19)
	csrc	mstatus, t0
	csrw	satp, zero
	sfence.vma
	la	t0, m_trap
	csrw	mtvec, t0
	mv	ra, s0
	ret

	// All aliases have identical PPN and attributes, including software A/D.
	// Changes invalidate the entire range rather than relying on a particular
	// implementation's NAPOT TLB-entry granularity.
	.macro	SET_NAPOT value
	li	t0, L0A + 16*8
	li	t1, \value
	addi	t2, t0, 16*8
.Lnapot_ptes\@:
	sd	t1, 0(t0)
	addi	t0, t0, 8
	bne	t0, t2, .Lnapot_ptes\@
	sfence.vma
	.endm

	.macro	CHECK_NAPOT_FETCH cause=9
	addi	s6, s6, 1
	mv	a7, s3			// preserve the current subpage's data VA
	addi	t3, s3, -0x100
	li	s2, \cause
	.if \cause == 12
	mv	s3, t3
	mv	s7, t3
	.else
	li	s3, 0			// successful code reaches S-mode ECALL
	addi	s7, t3, 4
	.endif
	la	s4, .Lnapot_fetch_resume\@
	li	s5, 0
	li	s10, 1
	li	t0, (3 << 11)
	csrc	mstatus, t0
	li	t0, (1 << 17) | (1 << 11)
	csrs	mstatus, t0
	csrw	mepc, t3
	mret
.Lnapot_fetch_resume\@:
	li	t0, 1
	bne	s5, t0, fail_svade
	.if \cause == 9
	li	t0, 16
	sub	t0, t0, s11
	bne	a0, t0, fail_svade	// distinct code marker for each physical subpage
	.endif
	li	s10, 0
	mv	s3, a7
	.endm

napot_checks:
	mv	a6, ra
	li	s10, 0
	// Build tiny code/data frames without a second firmware harness.
	li	t0, NAPOT_PA
	li	t1, 0
	li	t2, 16
1:
	slli	t3, t1, 20
	ori	t3, t3, 0x513		// addi a0,zero,subpage
	sw	t3, 0(t0)
	li	t3, 0x73		// ecall
	sw	t3, 4(t0)
	li	t3, 0x8877665544332200
	or	t3, t3, t1
	sd	t3, 0x100(t0)
	li	t3, 0x1000
	add	t0, t0, t3
	addi	t1, t1, 1
	bne	t1, t2, 1b
	fence.i
	SET_NAPOT NAPOT_LEAF | 0x4f // RWX, A=1,D=0, S-mode
	li	s3, NAPOT_VA + 0x100
	li	s8, NAPOT_PA + 0x100
	li	s11, 16
2:
	CHECK_DATA ld, 0, address=s3, physical=s8
	CHECK_DATA sd, 15, address=s3, physical=s8 // reject the load-filled D=0 TLB entry
	CHECK_DATA ld, 0, address=s3, physical=s8
	CHECK_NAPOT_FETCH
	li	t0, 0x1000
	add	s3, s3, t0
	add	s8, s8, t0
	addi	s11, s11, -1
	bnez	s11, 2b
	// No physical PTE may have gained D, including aliases of a cached entry.
	li	t0, L0A + 16*8
	li	t1, NAPOT_LEAF | 0x4f
	addi	t2, t0, 16*8
3:
	ld	t3, 0(t0)
	bne	t3, t1, fail_svade
	addi	t0, t0, 8
	bne	t0, t2, 3b
	SET_NAPOT NAPOT_LEAF | 0xcf // software sets D for every alias
	li	s3, NAPOT_VA + 0x100
	li	s8, NAPOT_PA + 0x100
	li	s11, 16
4:
	CHECK_DATA sd, 0, address=s3, physical=s8
	CHECK_DATA ld, 0, address=s3, physical=s8
	li	t0, 0x1000
	add	s3, s3, t0
	add	s8, s8, t0
	addi	s11, s11, -1
	bnez	s11, 4b
	li	s3, NAPOT_VA + 0x100
	li	s8, NAPOT_PA + 0x100
	SET_NAPOT NAPOT_LEAF | 0x0f
	CHECK_DATA ld, 13, address=s3, physical=s8
	CHECK_DATA sd, 15, address=s3, physical=s8
	CHECK_NAPOT_FETCH 12
	li	t0, L0A + 16*8
	ld	t0, 0(t0)
	li	t1, NAPOT_LEAF | 0x0f
	bne	t0, t1, fail_svade
	// Every reserved low-nibble size (including the all-zero PPN case)
	// faults on the reference and DUT; the standalone bench sweeps PPN[8:0].
	.irp nibble, 0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15
	SET_NAPOT ((NAPOT_PA >> 12) << 10) | (\nibble << 10) | PTE_N | 0xcf
	CHECK_DATA ld, 13, address=s3, physical=s8
	.endr
	SET_NAPOT PTE_N | 0xcf
	CHECK_DATA ld, 13, address=s3, physical=s8
	SET_NAPOT 0
	mv	ra, a6
	ret

	.section .text.pbmt, "ax"
	// level 3 is the 64 KiB NAPOT fixture, not an Sv39 walk level. Ordinary
	// superpages use a different VA offset to reach the same physical data.
	// t5/t6 retain the tested PTE address/value for the no-write checks.
	.macro	PBMT_MAP level, attr, flags=0xcf
	SET_PTE 0x80002000, PTR_L1A
	SET_PTE L1A, PTR_L0A
	.if \level == 3
	SET_NAPOT NAPOT_LEAF | (\attr << 61) | \flags
	li	s3, NAPOT_VA + 0x100
	li	s8, NAPOT_PA + 0x100
	li	t5, L0A + 16*8
	li	t6, NAPOT_LEAF | (\attr << 61) | \flags
	.else
	li	s8, FRAMEA + 0x100
	.if \level == 0
	li	s3, X_VA + 0x100
	li	t5, L0A + 4*8
	li	t6, ((FRAMEA >> 12) << 10) | (\attr << 61) | \flags
	.else
	li	s3, 0x8100
	.if \level == 1
	li	t5, L1A
	.else
	li	t5, 0x80002000
	.endif
	li	t6, ((0x80000000 >> 12) << 10) | (\attr << 61) | \flags
	.endif
	sd	t6, 0(t5)
	sfence.vma
	.endif
	.endm

	.macro	PBMT_MPRV
	li	t0, (3 << 11) | (1 << 18) | (1 << 19)
	csrc	mstatus, t0
	li	t0, (1 << 17) | (1 << 11)
	csrs	mstatus, t0
	.endm

	// Exact-width stores exercise every byte lane without widening an IO
	// access. Both signed and unsigned loads, untouched neighboring bytes,
	// and adjacent doublewords are checked after the reverse alias fence.
	.macro	PBMT_WIDTH store, load, signedload, value, signedvalue, offset, fullvalue
	addi	s6, s6, 1
	li	s2, 0
	li	s5, 0
	li	t1, 0x6655443322110099
	sd	t1, -8(s8)
	sd	t1, 8(s8)
	sd	zero, 0(s8)
	ld	t2, 0(s8)		// real cache-warm physical alias access
	PBMT_SYNC
	li	t1, \value
	PBMT_MPRV
	\store	t1, \offset(s3)
	\load	t2, \offset(s3)
	\signedload t3, \offset(s3)
	li	t0, (1 << 17)
	csrc	mstatus, t0
	PBMT_SYNC
	li	t0, \value
	bne	t2, t0, fail_svade
	li	t0, \signedvalue
	bne	t3, t0, fail_svade
	ld	t2, 0(s8)
	li	t0, \fullvalue
	bne	t2, t0, fail_svade
	li	t0, 0x6655443322110099
	ld	t2, -8(s8)
	bne	t2, t0, fail_svade
	ld	t2, 8(s8)
	bne	t2, t0, fail_svade
	.endm

	.macro	PBMT_ATOMIC width, initial, old, added, replacement, final
	addi	s6, s6, 1
	li	s2, 0
	li	s5, 0
	li	t1, \initial
	sd	t1, 0(s8)
	ld	t2, 0(s8)
	PBMT_SYNC
	li	t1, 2
	PBMT_MPRV
	amoadd.\width\().aqrl t2, t1, (s3)
	li	t0, (1 << 17)
	csrc	mstatus, t0
	PBMT_SYNC
	li	t0, \old
	bne	t2, t0, fail_svade
	ld	t2, 0(s8)
	li	t0, \added
	bne	t2, t0, fail_svade
	addi	s6, s6, 1
	PBMT_SYNC
	li	t1, \replacement
	PBMT_MPRV
.Lpbmt_lrsc\@:
	lr.\width\().aq t2, (s3)
	sc.\width\().rl t3, t1, (s3)
	bnez	t3, .Lpbmt_lrsc\@
	li	t0, (1 << 17)
	csrc	mstatus, t0
	PBMT_SYNC
	.ifc \width,w
	li	t0, 1
	.else
	li	t0, \added
	.endif
	bne	t2, t0, fail_svade
	ld	t2, 0(s8)
	li	t0, \final
	bne	t2, t0, fail_svade
	.endm

pbmt_checks:
	mv	a6, ra
	li	s10, 0
	// Enable/disable is checked by CSR readback as well as actual accesses.
	// Every leaf encoding is tested on 4 KiB, 2 MiB, 1 GiB and NAPOT
	// mappings, including a repeated access to exercise a populated TLB.
	.irp enabled, 0, 1
	addi	s6, s6, 1
	li	t0, PBMTE
	.if \enabled
	csrs	0x30a, t0
	.else
	csrc	0x30a, t0
	.endif
	csrr	t1, 0x30a
	and	t1, t1, t0
	.if \enabled
	bne	t1, t0, fail_svade
	.else
	bnez	t1, fail_svade
	.endif
	sfence.vma
	.irp attr, 0, 1, 2, 3
	.irp level, 0, 1, 2, 3
	PBMT_MAP \level, \attr
	.if (\attr == 3) || ((\enabled == 0) && (\attr != 0))
	CHECK_DATA ld, 13, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 15, address=s3, physical=s8, pbmt=1
	.else
	CHECK_DATA ld, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 0, address=s3, physical=s8, pbmt=1
	.endif
	ld	t0, 0(t5)
	bne	t0, t6, fail_svade
	.endr
	.endr
	.endr

	// Changing PBMTE is synchronized with a global SFENCE.VMA, as required
	// for a portable test. A previously valid NC translation must fault
	// while disabled, then succeed again once enabled and invalidated.
	PBMT_MAP 0, 1
	CHECK_DATA ld, 0, address=s3, physical=s8, pbmt=1
	li	t0, PBMTE
	csrc	0x30a, t0
	sfence.vma
	CHECK_DATA ld, 13, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 15, address=s3, physical=s8, pbmt=1
	li	t0, PBMTE
	csrs	0x30a, t0
	sfence.vma
	CHECK_DATA ld, 0, address=s3, physical=s8, pbmt=1

	// Pointer PBMT is reserved independently of PBMTE. Test both levels,
	// both data fault classes and all three nonzero encodings.
	.irp enabled, 0, 1
	li	t0, PBMTE
	.if \enabled
	csrs	0x30a, t0
	.else
	csrc	0x30a, t0
	.endif
	.irp attr, 1, 2, 3
	.irp level, 1, 2
	PBMT_MAP 0, 0
	.if \level == 1
	li	t5, L1A
	li	t6, PTR_L0A | (\attr << 61)
	.else
	li	t5, 0x80002000
	li	t6, PTR_L1A | (\attr << 61)
	.endif
	sd	t6, 0(t5)
	sfence.vma
	CHECK_DATA ld, 13, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 15, address=s3, physical=s8, pbmt=1
	ld	t0, 0(t5)
	bne	t0, t6, fail_svade
	.endr
	.endr
	.endr

	// PBMT changes neither privilege permissions nor Svade. A load-filled
	// TLB entry with D=0 must not permit a later store. MPRV=U and S+SUM/MXR
	// exercise the effective privilege rather than the bare M-mode driver.
	.irp attr, 1, 2
	PBMT_MAP 0, \attr, 0x4f
	CHECK_DATA ld, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 15, address=s3, physical=s8, pbmt=1
	PBMT_MAP 0, \attr, 0x0f
	CHECK_DATA ld, 13, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 15, address=s3, physical=s8, pbmt=1
	PBMT_MAP 0, \attr, 0xdf
	CHECK_DATA ld, 0, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 0, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA ld, 13, 1, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 15, 1, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA ld, 0, 1, 1, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 0, 1, 1, address=s3, physical=s8, pbmt=1
	PBMT_MAP 0, \attr, 0xd9
	CHECK_DATA ld, 13, 0, 0, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA ld, 0, 0, 0, 1, address=s3, physical=s8, pbmt=1

	PBMT_MAP 0, \attr
	PBMT_WIDTH sb, lbu, lb, 0x80, -128, 3, 0x80000000
	PBMT_WIDTH sh, lhu, lh, 0x8001, -32767, 2, 0x80010000
	PBMT_WIDTH sw, lwu, lw, 0x80000001, -2147483647, 4, 0x8000000100000000
	PBMT_WIDTH sd, ld, ld, 0x8877665544332211, 0x8877665544332211, 0, 0x8877665544332211
	PBMT_ATOMIC w, 0x88776655ffffffff, -1, 0x8877665500000001, 0x80000000, 0x8877665580000000
	PBMT_ATOMIC d, 0x8877665544332211, 0x8877665544332211, 0x8877665544332213, 0x1122334455667788, 0x1122334455667788

	// All sixteen NAPOT subpages retain the PBMT attributes independently.
	PBMT_MAP 3, \attr
	li	s11, 16
8:
	CHECK_DATA ld, 0, address=s3, physical=s8, pbmt=1
	CHECK_DATA sd, 0, address=s3, physical=s8, pbmt=1
	li	t0, 0x1000
	add	s3, s3, t0
	add	s8, s8, t0
	addi	s11, s11, -1
	bnez	s11, 8b
	.endr

	// Repeated same-VA changes include actual dirty/warm PMA accesses,
	// NC/IO stores, and reverse transitions. CHECK_DATA orders and flushes
	// both sides of every differently-cacheable alias access.
	.irp attr, 0, 1, 2, 1, 0, 2, 0
	PBMT_MAP 0, \attr
	CHECK_DATA sd, 0, address=s3, physical=s8, pbmt=1, value=(0x1122334455667700 + \attr)
	CHECK_DATA ld, 0, address=s3, physical=s8, pbmt=1
	.endr

	// An unaligned main-memory doubleword may span PMA and NC pages. Both
	// directions matter: each half must keep its own translated attribute.
	// IO is deliberately excluded: Svpbmt permits stricter IO alignment
	// PMAs, so a universal Spike-vs-DUT result would not be meaningful.
	li	t0, FRAMEB
	ld	a4, 0(t0)		// preserve the following U-mode test's code
	.irp first, 0, 1
	PBMT_MAP 0, \first
	SET_PTE L0A + 5*8, ((FRAMEB >> 12) << 10) | ((1 - \first) << 61) | 0xcf
	addi	s6, s6, 1
	li	s2, 0
	li	s5, 0
	li	s3, X_VA + 0xffc
	li	s8, FRAMEA + 0xff8
	li	a3, FRAMEB
	li	t0, 0xa3a2a1a0b3b2b1b0
	sd	t0, 0(s8)
	li	t0, 0xc3c2c1c0d3d2d1d0
	sd	t0, 0(a3)
	ld	t1, 0(s8)
	ld	t2, 0(a3)
	// An unrelated bare block distinguishes the next physical beat from
	// the previous translated access's PA2. Keep a5 live across MPRV changes.
	li	a5, NAPOT_PA + 0x200
	li	t0, 0x44332211aabbccdd
	sd	t0, 0(a5)
	li	t0, 0x12345678ffeeddcc
	sd	t0, 8(a5)
	addi	a5, a5, 4
	PBMT_SYNC
	PBMT_SYNC a3
	PBMT_MPRV
	ld	t2, 0(s3)
	li	t0, 0xd3d2d1d0a3a2a1a0
	bne	t2, t0, fail_svade
	li	t2, 0x8877665544332211
	sd	t2, 0(s3)
	ld	t3, 0(s3)
	bne	t3, t2, fail_svade
	li	t0, (1 << 17)
	csrc	mstatus, t0
	// No intervening LSU operation: the previous translated instruction
	// crossed a page, but this first Bare load must form PA2 from its own PA.
	addi	s6, s6, 1
	ld	t2, 0(a5)
	li	t0, 0xffeeddcc44332211
	bne	t2, t0, fail_svade
	// Repeat for a first-Bare store, including untouched-byte canaries.
	PBMT_MPRV
	ld	t2, 0(s3)
	li	t0, (1 << 17)
	csrc	mstatus, t0
	addi	s6, s6, 1
	li	t2, 0x0123456789abcdef
	sd	t2, 0(a5)
	ld	t2, -4(a5)
	li	t0, 0x89abcdefaabbccdd
	bne	t2, t0, fail_svade
	ld	t2, 4(a5)
	li	t0, 0x1234567801234567
	bne	t2, t0, fail_svade
	PBMT_SYNC
	PBMT_SYNC a3
	ld	t2, 0(s8)
	li	t0, 0x44332211b3b2b1b0
	bne	t2, t0, fail_svade
	ld	t2, 0(a3)
	li	t0, 0xc3c2c1c088776655
	bne	t2, t0, fail_svade
	.endr

	// The following U-mode tests still execute the original frameB code.
	li	t0, FRAMEB
	sd	a4, 0(t0)
	fence.i
	SET_NAPOT 0
	SET_PTE 0x80002000, PTR_L1A
	SET_PTE L1A, PTR_L0A
	SET_PTE L0A + 4*8, LEAF_A
	SET_PTE L0A + 5*8, 0
	li	t0, PBMTE
	csrc	0x30a, t0
	sfence.vma
	mv	ra, a6
	ret

	// The last instruction of the executable page is a scalar LSU operation.
	// Its successor is unmapped. Fetch warms the instruction walker's PWC
	// line containing both code PTEs; the data walk is cold and follows a
	// different L1/L0 branch. This exposes the younger instruction fault while
	// the older data access still owns the LSU, including its second walk.
	// The optional HTIF observer requires actual overlap for all five cases;
	// architectural checks alone must not be treated as proof of overlap.
	.equ	ORDER_DATA_VA,	0x00406000 // vpn1=2, vpn0=6; next page vpn0=7
	.equ	ORDER_PA1,	NAPOT_PA + 0x2000
	.equ	ORDER_PA2,	NAPOT_PA + 0x5000 // deliberately noncontiguous
	.equ	ORDER_LO,	0xa3a2a1a0b3b2b1b0
	.equ	ORDER_HI,	0xc3c2c1c0d3d2d1d0
	.equ	ORDER_STORE,	0x8877665544332211
	.equ	ORDER_CANARY,	0x1122334455667788
	.equ	ORDER_RD,	0x0123456789abcdef
	.macro	ORDER_CASE phase, split=0, store=0, datafault=0
	addi	s6, s6, 1
	li	t0, L0B + 6*8
	li	t1, ((ORDER_PA1 >> 12) << 10) | 0xcf
	sd	t1, 0(t0)
	.if \datafault
	sd	zero, 8(t0)
	.else
	li	t1, ((ORDER_PA2 >> 12) << 10) | 0xcf
	sd	t1, 8(t0)
	.endif
	li	s8, ORDER_PA1 + 0xff8
	li	s9, ORDER_PA2
	li	t1, ORDER_LO
	sd	t1, 0(s8)
	li	t1, ORDER_HI
	sd	t1, 0(s9)
	li	t1, ORDER_CANARY
	sd	t1, -8(s8)
	sd	t1, 8(s9)
	li	t0, ORDER_PA1 + 0x100
	sd	t1, 0(t0)
	li	t0, FRAMEA + 0xffc
	.if \store
	li	t1, 0x00c5b023		// sd a2,0(a1)
	.else
	li	t1, 0x0005b503		// ld a0,0(a1)
	.endif
	sw	t1, 0(t0)
	fence.i
	sfence.vma
	li	a0, ORDER_RD
	li	a2, ORDER_STORE
	.if \split
	li	a1, ORDER_DATA_VA + 0xffc
	.else
	li	a1, ORDER_DATA_VA + 0x100
	.endif
	.if \store || \datafault
	li	a4, ORDER_RD
	.elseif \split
	li	a4, 0xd3d2d1d0a3a2a1a0
	.else
	li	a4, ORDER_CANARY
	.endif
	.if \datafault
	li	s2, 13 + (2 * \store)
	li	s3, ORDER_DATA_VA + 0x1000
	li	s7, X_VA + 0xffc
	.else
	li	s2, 12
	li	s3, X_VA + 0x1000
	mv	s7, s3
	.endif
	la	s4, .Lorder_resume\@
	li	s5, 0
	li	t0, ORDER_PHASE
	li	t1, \phase
	sd	t1, 0(t0)
	li	t0, (3 << 11) | (1 << 17) | (1 << 18) | (1 << 19)
	csrc	mstatus, t0
	li	t0, (1 << 11)
	csrs	mstatus, t0
	li	t0, X_VA + 0xffc
	csrw	mepc, t0
	mret
.Lorder_resume\@:
	li	t0, ORDER_PHASE
	sd	zero, 0(t0)
	li	t0, 1
	bne	s5, t0, fail_svade
	bne	a0, a4, fail_svade
	li	t0, ORDER_STORE
	bne	a2, t0, fail_svade	// store operand / load-source canary
	.if \split
	li	t0, ORDER_DATA_VA + 0xffc
	.else
	li	t0, ORDER_DATA_VA + 0x100
	.endif
	bne	a1, t0, fail_svade
	ld	t0, -8(s8)
	li	t1, ORDER_CANARY
	bne	t0, t1, fail_svade
	ld	t0, 8(s9)
	bne	t0, t1, fail_svade
	ld	t0, 0(s8)
	.if \store && !\datafault
	li	t1, 0x44332211b3b2b1b0
	.else
	li	t1, ORDER_LO
	.endif
	.if \store && \datafault
	// Scalar misaligned stores may commit the first half before a
	// second-page fault. Spike
	// does so. Accept either permitted value here; +ifu_faultcheck also
	// requires that Karu's stronger preflight emits no LSU memory request.
	beq	t0, t1, .Lorder_first_ok\@
	li	t1, 0x44332211b3b2b1b0
	.endif
	bne	t0, t1, fail_svade
.Lorder_first_ok\@:
	ld	t0, 0(s9)
	.if \store && !\datafault
	li	t1, 0xc3c2c1c088776655
	.else
	li	t1, ORDER_HI
	.endif
	bne	t0, t1, fail_svade
	li	t0, L0B + 6*8
	ld	t1, 0(t0)
	li	t2, ((ORDER_PA1 >> 12) << 10) | 0xcf
	bne	t1, t2, fail_svade
	ld	t1, 8(t0)
	.if \datafault
	bnez	t1, fail_svade
	.else
	li	t2, ((ORDER_PA2 >> 12) << 10) | 0xcf
	bne	t1, t2, fail_svade
	.endif
	.endm

fault_order_checks:
	mv	a6, ra
	la	t0, order_trap
	csrw	mtvec, t0
	SET_PTE L0A + 4*8, LEAF_A & ~PTE_U
	SET_PTE L0A + 5*8, 0
	SET_PTE L1A + 2*8, PTR_L0B
	ORDER_CASE 1
	ORDER_CASE 2, 1
	ORDER_CASE 3, 1, 1
	ORDER_CASE 4, 1, 0, 1
	ORDER_CASE 5, 1, 1, 1
	SET_PTE L1A + 2*8, 0
	SET_PTE L0B + 6*8, 0
	SET_PTE L0B + 7*8, 0
	SET_PTE L0A + 4*8, LEAF_A
	la	t0, svade_trap
	csrw	mtvec, t0
	mv	ra, a6
	ret

	.balign 4
order_trap:
	// Check the older load result before changing data context or running
	// any LSU operation in the handler. A faulting older load keeps rd.
	bne	a0, a4, fail_svade
	csrr	t0, mcause
	bne	t0, s2, fail_svade
	csrr	t0, mtval
	bne	t0, s3, fail_svade
	csrr	t0, mepc
	bne	t0, s7, fail_svade
	addi	s5, s5, 1
	li	t0, (3 << 11)
	csrs	mstatus, t0
	csrw	mepc, s4
	mret

	.section .text.svade, "ax"
check_fetch_a0:
	mv	s1, ra
	addi	s6, s6, 1
	li	s2, 12
	li	s3, X_VA
	li	s7, X_VA
	la	s4, fetch_a0_resume
	li	s5, 0
	li	s10, 1
	li	t0, (3 << 11) | (1 << 8)
	csrc	mstatus, t0		//	MPP=U, SPP=U
	li	t0, (1 << 17)
	csrs	mstatus, t0
	bnez	a1, fetch_a0_sret
	csrw	mepc, s3
	mret
fetch_a0_sret:
	csrw	sepc, s3
	sret
fetch_a0_resume:
	li	t0, 1
	bne	s5, t0, fail_svade
	li	t0, L0A + 4*8
	ld	t0, 0(t0)
	andi	t0, t0, PTE_A
	bnez	t0, fail_svade
	mv	ra, s1
	ret

check_return_s:
	mv	s1, ra
	addi	s6, s6, 1
	li	s2, 9			//	expected S-mode ecall
	li	s3, 0
	la	s7, return_s_ecall
	la	s4, return_s_resume
	li	s5, 0
	li	s10, 1
	li	t0, (3 << 11)
	csrc	mstatus, t0
	li	t0, (1 << 17) | (1 << 11) | (1 << 8)
	csrs	mstatus, t0		//	MPRV=1, MPP=S, SPP=S
	bnez	a1, return_s_sret
	csrw	mepc, s7
	mret
return_s_sret:
	csrw	sepc, s7
	sret
return_s_ecall:
	ecall
return_s_resume:
	li	t0, 1
	bne	s5, t0, fail_svade
	mv	ra, s1
	ret

	.balign 4
svade_trap:
	csrr	t0, mcause
	bne	t0, s2, fail_svade
	csrr	t0, mtval
	bne	t0, s3, fail_svade
	csrr	t0, mepc
	bne	t0, s7, fail_svade
	beqz	s10, 1f
	csrr	t0, mstatus
	srli	t0, t0, 17
	andi	t0, t0, 1
	bnez	t0, fail_svade	//	xRET below M must have cleared MPRV
1:
	addi	s5, s5, 1
	csrw	mepc, s4
	li	t0, (1 << 17)
	csrc	mstatus, t0
	li	t0, (3 << 11)
	csrs	mstatus, t0		//	resume the bare M-mode driver
	mret
fail_svade:
	addi	t0, s6, 0x20
	slli	t0, t0, 1
	ori	t0, t0, 1
	li	t1, TOHOST
	li	t2, (1 << 17)
	csrc	mstatus, t2
	sd	t0, 0(t1)
1:	j	1b

	.section .text.boot, "ax"
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
