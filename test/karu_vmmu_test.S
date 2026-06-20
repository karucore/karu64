//	karu_vmmu_test.S
//	Vector load/store through Sv39 (phases V2 + V3 + V4 of
//	doc/architecture.md). S-mode, one page-table root. Phases A-H run
//	UNDELEGATED (all traps -> M m_trap); phase I then delegates page faults
//	(medeleg includes 13/15) and exercises the S-mode stvec/scause/stval/sepc path
//	plus an S-mode demand-map + sret restart; phase J executes vector memory
//	in U mode from a U-executable page with U data PTEs.
//
//	VA map (vpn2=0,vpn1=0):    phys frames (deliberately NON-adjacent):
//	  V0 = 0x4000  -> F0 = 0x8000_5000   (RW data)
//	  V1 = 0x5000  -> F1 = 0x8000_7000   (RW data; VA-adjacent to V0!)
//	  VF = 0x6000  -> unmapped           (the fault page)
//	  VR = 0x7000  -> unmapped, demand-mapped to F2 = 0x8000_8000 by m_trap
//	  VR2= 0x8000  -> unmapped, demand-mapped to F2 by s_vtrap
//	  UC = 0x9000  -> UCODE_PHYS = 0x8000_9000 (U X test code)
//	  UV0= 0xA000  -> F0 (U RW alias)
//	  UV1= 0xB000  -> F1 (U RW alias; VA-adjacent to UV0)
//	plus a 1 GiB identity leaf for region 2 (0x8000_0000, S RWX) so the
//	driver can inspect physical frames directly.
//
//	Subtests (exit code on fail):
//	  A (2)  cross-page contiguous vle8: 32 bytes spanning V0->V1 must come
//	         from the two distinct phys frames (2-page preflight composition).
//	  B (3)  cross-page contiguous vse8: ditto for the store path.
//	  C (4)  strided vlse16 walking V0->V1, incl. one element straddling the
//	         page boundary (per-element translate + the 2nd-page xlate).
//	  D (5)  vle8 from VF: cause 13, mtval=VF, and vd UNCHANGED.
//	  E (6)  vse8 spanning V1->VF: cause 15 AND the mapped V1 tail bytes
//	         UNCHANGED (preflight = no side effects before the fault).
//	  F (7)  vle8ff spanning V1->VF: NO trap, vl trimmed to 16, first 16
//	         bytes loaded, rest of vd undisturbed.
//	  G (8)  vle8 from VR: fault once, m_trap demand-maps F2 + sfence and
//	         RETRIES (mepc unchanged); op completes with F2 data.
//	  H (9)  MASKED tail on the unmapped page (review finding): vle8/vse8
//	         with elements 16..31 inactive spanning V1->VF must not trap,
//	         and vle8ff must not trim -- inactive elements are never
//	         translated or accessed.
//	  I (10) DELEGATED faults (V3 gate): a faulting vector load lands at
//	         stvec with scause/stval/sepc correct, and an S-mode demand-map
//	         + sret RESTARTS it.
//	  J (11) U-mode vector memory (V4 gate): U-executed vle/vse/vlse/vsse/
//	         vlux/vsux through U PTEs, returning through delegated U ecall.
//	  K-O run with page faults delegated to S (from phase I); s_vtrap records.
//	  K (12) load-only page: vector LOAD ok, vector STORE -> cause 15.
//	  L (13) SUM: S-mode vector load from a U-page faults 13 without SUM,
//	         succeeds with sstatus.SUM=1.
//	  M (14) MXR: vector load from an execute-only page faults 13 without
//	         MXR, succeeds with sstatus.MXR=1.
//	  N (15) Svadu: a store to a W,D=0 page does NOT fault and HW writes
//	         back A+D into the PTE (karu always; spike needs _svadu in isa).
//	  O (16) invalid PTE (V=0): vector load -> cause 13.
//	exit 0 = all pass. The harness prints "[HTIF] exit <code>".

	.equ	TOHOST,		0x80001000
	.equ	TRAPS_VAR,	0x80001008	//	trap counter
	.equ	MCAUSE_VAR,	0x80001010
	.equ	MTVAL_VAR,	0x80001018
	.equ	TMODE_VAR,	0x80001020	//	0 = record+skip(+4); 1 = demand-map+retry
									//	2 = ecall service: delegate 8/13/15 to S
	.equ	T1SAVE_VAR,	0x80001028	//	m_trap t1 spill (t0 goes to mscratch)
	.equ	SCAUSE_VAR,	0x80001040	//	s_vtrap records (delegated faults)
	.equ	STVAL_VAR,	0x80001048
	.equ	SEPC_VAR,	0x80001050
	.equ	SMODE_VAR,	0x80001058	//	0 = record+skip(+4); 1 = demand-map+retry
									//	2 = U ecall return to s_after_u
	.equ	STRAPS_VAR,	0x80001060	//	s_vtrap counter
	.equ	T1SAVE2_VAR,0x80001068	//	s_vtrap t1 spill (t0 goes to sscratch)

	//	absolute tohost/fromhost symbols so the SAME ELF terminates on spike
	.globl	tohost
	.globl	fromhost
	.set	tohost,   TOHOST
	.set	fromhost, 0x80001030

	.equ	ROOT,		0x80002000
	.equ	L1T,		0x80003000
	.equ	L0T,		0x80004000
	.equ	F0,			0x80005000
	.equ	F1,			0x80007000
	.equ	F2,			0x80008000
	.equ	UCODE_PHYS,	0x80009000
	.equ	V0,			0x4000
	.equ	V1,			0x5000
	.equ	VF,			0x6000
	.equ	VR,			0x7000
	.equ	VR2,		0x8000		//	demand-mapped by the S handler (phase I)
	.equ	UCODE_VA,	0x9000
	.equ	UV0,		0xA000
	.equ	UV1,		0xB000

	.equ	PTE_V,		0x01
	.equ	PTE_R,		0x02
	.equ	PTE_W,		0x04
	.equ	PTE_X,		0x08
	.equ	PTE_U,		0x10
	.equ	PTE_A,		0x40
	.equ	PTE_D,		0x80
	.equ	PTR_L1,		((L1T >> 12) << 10) | PTE_V
	.equ	PTR_L0,		((L0T >> 12) << 10) | PTE_V
	.equ	LEAF_F0,	((F0 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_A|PTE_D
	.equ	LEAF_F1,	((F1 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_A|PTE_D
	.equ	LEAF_F2,	((F2 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_A|PTE_D
	.equ	LEAF_UCODE,	((UCODE_PHYS >> 12) << 10) | PTE_V|PTE_R|PTE_X|PTE_U|PTE_A|PTE_D
	.equ	LEAF_UF0,	((F0 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D
	.equ	LEAF_UF1,	((F1 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D
	//	V4 permission-matrix leaves (alias F2; perms vary):
	.equ	LEAF_RO,	((F2 >> 12) << 10) | PTE_V|PTE_R|PTE_A|PTE_D		//	load-only (no W)
	.equ	LEAF_XO,	((F2 >> 12) << 10) | PTE_V|PTE_X|PTE_A|PTE_D		//	exec-only (no R) -> MXR
	.equ	LEAF_WND,	((F2 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_A		//	W, D=0 -> Svadu writeback
	.equ	IDENT2,		((0x80000000 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_X|PTE_A|PTE_D
	.equ	SATP0,		(8 << 60) | (ROOT >> 12)

//	====================================================================
//	M-mode entry: FS/VS on (spike), prefill frames, drop to S.
//	====================================================================
	.section .text.boot, "ax"
	.globl	_start
_start:
	la	t0, m_trap
	csrw	mtvec, t0
	li	t0, 0x6600		//	FS=11 VS=11 (spike resets them Off)
	csrs	mstatus, t0
	//	menvcfg.ADUE (bit 61) = 1: enable HW A/D-bit update so a store to a
	//	D=0 page writes the bit back instead of faulting (phase N). karu_sv39
	//	does this unconditionally (menvcfg reads 0 there, a no-op); spike
	//	gates on ADUE, so set it -> identical observable behavior, same ELF.
	li	t0, 1
	slli	t0, t0, 61
	csrs	0x30a, t0		//	menvcfg

	//	prefill F0 with byte (0x40+i)&0xFF, F1 with (0x80+i)&0xFF,
	//	F2 with (0xC0+i)&0xFF over the full 4 KiB
	li	t0, F0
	li	t1, 0x40
	jal	ra, fillpage
	li	t0, F1
	li	t1, 0x80
	jal	ra, fillpage
	li	t0, F2
	li	t1, 0xC0
	jal	ra, fillpage

	//	enter S at s_driver
	csrr	t0, mstatus
	li	t1, ~(3 << 11)
	and	t0, t0, t1
	li	t1, (1 << 11)
	or	t0, t0, t1		//	MPP = S
	csrw	mstatus, t0
	la	t0, s_driver
	csrw	mepc, t0
	mret

fillpage:				//	t0 = page base, t1 = seed; clobbers t2,t3
	li	t2, 0
1:	add	t3, t1, t2
	add	t4, t0, t2
	sb	t3, 0(t4)
	addi	t2, t2, 1
	li	t3, 4096
	bne	t2, t3, 1b
	ret

//	====================================================================
//	M trap handler. TMODE 0: count + record cause/tval, skip the 4-byte
//	insn. TMODE 1: demand-map VR -> F2 (patch L0[7]), sfence, RETRY the
//	same instruction (mepc untouched).
//	====================================================================
	.balign 4
m_trap:
	//	preserve t0/t1: the demand-map path RE-EXECUTES the faulting insn
	//	verbatim, so its base register must come back intact (the first
	//	version clobbered t1 -> the retried vle8 faulted at LEAF_F2-as-VA).
	csrw	mscratch, t0
	li	t0, T1SAVE_VAR
	sd	t1, 0(t0)
	li	t0, TRAPS_VAR
	ld	t1, 0(t0)
	addi	t1, t1, 1
	sd	t1, 0(t0)
	csrr	t1, mcause
	li	t0, MCAUSE_VAR
	sd	t1, 0(t0)
	csrr	t1, mtval
	li	t0, MTVAL_VAR
	sd	t1, 0(t0)
	li	t0, TMODE_VAR
	ld	t1, 0(t0)
	beqz	t1, m_skip
	addi	t1, t1, -1
	beqz	t1, m_map_retry
	//	TMODE 2: ecall-from-S service -- delegate U ecall + page faults to S
	li	t1, (1 << 8) | (1 << 13) | (1 << 15)
	csrw	medeleg, t1
m_skip:
	csrr	t0, mepc
	addi	t0, t0, 4
	csrw	mepc, t0
	j	m_trap_ret
m_map_retry:
	li	t0, L0T + 7*8		//	L0[7] = VR leaf
	li	t1, LEAF_F2
	sd	t1, 0(t0)
	sfence.vma			//	mepc unchanged -> re-execute
m_trap_ret:
	li	t0, T1SAVE_VAR
	ld	t1, 0(t0)
	csrr	t0, mscratch
	mret

//	====================================================================
//	S trap handler (delegated page faults and U ecall). Same shape as
//	m_trap: t0 -> sscratch, t1 -> a fixed slot; SMODE 0 records cause/
//	tval/epc and skips the insn, SMODE 1 demand-maps VR2 -> F2 and
//	RETRIES (sepc untouched), SMODE 2 treats a U ecall as test completion
//	and returns to the S-mode continuation label.
//	====================================================================
	.balign 4
s_vtrap:
	csrw	sscratch, t0
	li	t0, T1SAVE2_VAR
	sd	t1, 0(t0)
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	addi	t1, t1, 1
	sd	t1, 0(t0)
	csrr	t1, scause
	li	t0, SCAUSE_VAR
	sd	t1, 0(t0)
	csrr	t1, stval
	li	t0, STVAL_VAR
	sd	t1, 0(t0)
	csrr	t1, sepc
	li	t0, SEPC_VAR
	sd	t1, 0(t0)
	li	t0, SMODE_VAR
	ld	t1, 0(t0)
	beqz	t1, s_skip
	addi	t1, t1, -1
	beqz	t1, s_map_retry
	addi	t1, t1, -1
	beqz	t1, s_u_done
s_skip:
	csrr	t0, sepc
	addi	t0, t0, 4
	csrw	sepc, t0
	j	s_vtrap_ret
s_map_retry:
	li	t0, L0T + 8*8		//	L0[8] = VR2 leaf
	li	t1, LEAF_F2
	sd	t1, 0(t0)
	sfence.vma			//	sepc unchanged -> re-execute
	j	s_vtrap_ret
s_u_done:
	la	t0, s_after_u
	csrw	sepc, t0
	csrr	t0, sstatus
	li	t1, (1 << 8)		//	SPP = S for the return from s_vtrap
	or	t0, t0, t1
	csrw	sstatus, t0
s_vtrap_ret:
	li	t0, T1SAVE2_VAR
	ld	t1, 0(t0)
	csrr	t0, sscratch
	sret

//	====================================================================
//	S-mode driver
//	====================================================================
	.balign 4
s_driver:
	li	t0, SATP0
	csrw	satp, t0
	sfence.vma

	//	---- A: cross-page contiguous LOAD ----
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, V0 + 0xFF0
	vle8.v	v8, (t1)
	li	t1, V0 + 0x100		//	park the result somewhere mapped
	vse8.v	v8, (t1)
	li	a0, F0 + 0x100		//	dst (phys)
	li	a1, F0 + 0xFF0		//	src lo 16 (phys)
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_a
	li	a0, F0 + 0x110
	li	a1, F1			//	src hi 16 (phys: the OTHER frame)
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_a

	//	---- B: cross-page contiguous STORE ----
	li	t1, V1 + 0x200		//	load a known 32B pattern (F1+0x200)
	vle8.v	v8, (t1)
	li	t1, V0 + 0xFF8		//	store spanning V0->V1
	vse8.v	v8, (t1)
	li	a0, F0 + 0xFF8
	li	a1, F1 + 0x200
	li	a2, 8
	jal	ra, cmpn
	bnez	a0, fail_b
	li	a0, F1
	li	a1, F1 + 0x208
	li	a2, 24
	jal	ra, cmpn
	bnez	a0, fail_b
	//	repair F1[0..23] for later phases (re-fill from M pattern is overkill;
	//	phases below use F1+0xFF0 and F2 only)

	//	---- C: strided vlse16, incl. a page-straddling element ----
	li	t0, 4
	vsetvli	t0, t0, e16, m1, tu, mu
	li	t1, V0 + 0xFFC
	li	t2, 8
	vlse16.v v8, (t1), t2	//	0x4FFC 0x5004 0x500C 0x5014 (no straddle)
	li	t1, V0 + 0x300
	vse16.v	v8, (t1)
	li	a0, F0 + 0x300		//	expected: F0[FFC,FFD] F1[004,005] F1[00C,00D] F1[014,015]
	li	a1, F0 + 0xFFC
	li	a2, 2
	jal	ra, cmpn
	bnez	a0, fail_c
	li	a0, F0 + 0x302
	li	a1, F1 + 0x004
	li	a2, 2
	jal	ra, cmpn
	bnez	a0, fail_c
	li	t0, 2
	vsetvli	t0, t0, e16, m1, tu, mu
	li	t1, V0 + 0xFFF		//	element 0 STRADDLES the V0/V1 page boundary
	li	t2, 16
	vlse16.v v8, (t1), t2
	li	t1, V0 + 0x310
	vse16.v	v8, (t1)
	li	t1, F0 + 0x310		//	expected byte 0 = F0[0xFFF], byte 1 = F1[0]
	lbu	t2, 0(t1)
	li	t3, F0 + 0xFFF
	lbu	t4, 0(t3)
	bne	t2, t4, fail_c
	lbu	t2, 1(t1)
	li	t3, F1
	lbu	t4, 0(t3)
	bne	t2, t4, fail_c

	//	---- D: load fault precision ----
	li	t0, TRAPS_VAR		//	zero the trap stats
	sd	zero, 0(t0)
	li	t0, 16
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xEE
	vmv.v.x	v8, t1			//	canary
	li	t1, VF
	vle8.v	v8, (t1)		//	-> cause 13, skipped by m_trap
	li	t0, TRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_d		//	exactly one trap
	li	t0, MCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 13
	bne	t1, t2, fail_d		//	load page fault
	li	t0, MTVAL_VAR
	ld	t1, 0(t0)
	li	t2, VF
	bne	t1, t2, fail_d		//	tval = the faulting VA
	li	t1, V0 + 0x400		//	vd must still be the canary
	vse8.v	v8, (t1)
	li	t0, F0 + 0x400
	li	t1, 16
1:	lbu	t2, 0(t0)
	li	t3, 0xEE
	bne	t2, t3, fail_d
	addi	t0, t0, 1
	addi	t1, t1, -1
	bnez	t1, 1b

	//	---- E: store fault. Two spec-legal behaviors, distinguished by the
	//	vstart the trap left behind:
	//	  vstart == 0  (karu: precise preflight) -> NOTHING stored, the
	//	               mapped V1 tail still holds the original fill pattern;
	//	  vstart == 16 (spike: element-wise progress) -> the 16 mapped bytes
	//	               WERE stored; clear vstart before continuing.
	li	t0, TRAPS_VAR
	sd	zero, 0(t0)
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, V0 + 0x500
	vle8.v	v8, (t1)		//	some data to store (= F0[0x500..])
	li	t1, V1 + 0xFF0		//	16 mapped bytes then 16 unmapped
	vse8.v	v8, (t1)		//	-> cause 15
	li	t0, TRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_e
	li	t0, MCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 15
	bne	t1, t2, fail_e		//	store/AMO page fault
	csrr	t0, vstart
	beqz	t0, 2f			//	0 -> precise-preflight check
	li	t1, 16
	bne	t0, t1, fail_e		//	anything else is wrong
	csrw	vstart, zero		//	element-wise impl: resume state consumed
	li	a0, F1 + 0xFF0		//	partial commit: mapped tail == stored data
	li	a1, F0 + 0x500
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_e
	j	3f
2:	li	a0, F1 + 0xFF0		//	preflight: mapped tail UNTOUCHED -- still
	li	t0, 0			//	the fill pattern (0x80 + (0xFF0+i)) & 0xFF
1:	lbu	t1, 0(a0)
	li	t2, 0xFF0
	add	t2, t2, t0
	addi	t2, t2, 0x80
	andi	t2, t2, 0xFF
	bne	t1, t2, fail_e
	addi	a0, a0, 1
	addi	t0, t0, 1
	li	t2, 16
	bne	t0, t2, 1b
3:

	//	---- F: vle8ff trims at the page boundary, no trap ----
	li	t0, TRAPS_VAR
	sd	zero, 0(t0)
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xEE
	vmv.v.x	v8, t1
	li	t1, V1 + 0xFF0
	vle8ff.v v8, (t1)		//	16 mapped + 16 unmapped -> vl = 16, NO trap
	csrr	s0, vl
	li	t0, TRAPS_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_f		//	must not trap
	li	t1, 16
	bne	s0, t1, fail_f		//	vl trimmed to the boundary
	csrr	t1, vstart
	bnez	t1, fail_f		//	completed op cleared vstart
	li	t0, 32			//	restore vl, park v8, check halves
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, V0 + 0x600
	vse8.v	v8, (t1)
	li	a0, F0 + 0x600		//	first 16: loaded from F1 tail
	li	a1, F1 + 0xFF0
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_f
	li	t0, F0 + 0x610		//	last 16: canary (undisturbed)
	li	t1, 16
1:	lbu	t2, 0(t0)
	li	t3, 0xEE
	bne	t2, t3, fail_f
	addi	t0, t0, 1
	addi	t1, t1, -1
	bnez	t1, 1b

	//	---- G: demand-map retry (Linux page-in pattern) ----
	li	t0, TRAPS_VAR
	sd	zero, 0(t0)
	li	t0, TMODE_VAR
	li	t1, 1
	sd	t1, 0(t0)		//	m_trap: map VR -> F2 and RETRY
	li	t0, 16
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, VR
	vle8.v	v8, (t1)		//	faults once, completes on retry
	li	t0, TMODE_VAR
	sd	zero, 0(t0)
	li	t0, TRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_g		//	exactly one fault+map
	li	t1, V0 + 0x700
	vse8.v	v8, (t1)
	li	a0, F0 + 0x700
	li	a1, F2
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_g

	//	---- H: MASK-BLINDNESS regression (review finding). vl=32 e8 at
	//	V1+0xFF0 with elements 0..15 active (mapped) and 16..31 MASKED OFF
	//	(on the unmapped page): plain load and store must not trap or touch
	//	VF, and vle8ff must neither trap NOR trim vl. ----
	li	t0, TRAPS_VAR
	sd	zero, 0(t0)
	li	t0, 1
	vsetvli	t0, t0, e64, m1, tu, mu
	li	t1, 0xFFFF
	vmv.s.x	v0, t1			//	mask: elements 0..15 active
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xEE
	vmv.v.x	v8, t1			//	canary (unmasked splat)
	li	t1, V1 + 0xFF0
	vle8.v	v8, (t1), v0.t		//	must NOT trap (inactive tail unmapped)
	vse8.v	v8, (t1), v0.t		//	must NOT trap either
	vle8ff.v v8, (t1), v0.t		//	must NOT trap and must NOT trim
	csrr	s0, vl
	li	t0, TRAPS_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_h		//	any trap = mask-blind translation
	li	t1, 32
	bne	s0, t1, fail_h		//	vleff trimmed a masked-off tail
	li	t0, 32			//	park v8: actives = F1 tail, rest canary
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, V0 + 0x800
	vse8.v	v8, (t1)
	li	a0, F0 + 0x800
	li	a1, F1 + 0xFF0
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_h
	li	t0, F0 + 0x810		//	masked-off elements: canary kept
	li	t1, 16
1:	lbu	t2, 0(t0)
	li	t3, 0xEE
	bne	t2, t3, fail_h
	addi	t0, t0, 1
	addi	t1, t1, -1
	bnez	t1, 1b

	//	---- I: DELEGATED vector page faults (V3 gate). medeleg 13/15 -> S;
	//	a faulting vector load must arrive at stvec with scause/stval/sepc
	//	correct, and an S-mode demand-map + sret must restart it. ----
	la	t0, s_vtrap
	csrw	stvec, t0
	li	t0, TMODE_VAR		//	ask M to set medeleg (ecall service)
	li	t1, 2
	sd	t1, 0(t0)
	ecall
	li	t0, TMODE_VAR
	sd	zero, 0(t0)
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t0, SMODE_VAR
	sd	zero, 0(t0)		//	record + skip
	li	t0, 16
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xEE
	vmv.v.x	v8, t1
	li	t1, VF
i_fault_insn:
	vle8.v	v8, (t1)		//	-> DELEGATED: lands at s_vtrap
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_i		//	exactly one delegated trap
	li	t0, SCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 13
	bne	t1, t2, fail_i		//	scause = load page fault
	li	t0, STVAL_VAR
	ld	t1, 0(t0)
	li	t2, VF
	bne	t1, t2, fail_i		//	stval = faulting VA
	li	t0, SEPC_VAR
	ld	t1, 0(t0)
	la	t2, i_fault_insn
	bne	t1, t2, fail_i		//	sepc = the vector insn itself
	csrr	t1, vstart
	bnez	t1, fail_i		//	precise abort: vstart untouched (0)
	li	t1, V0 + 0xA00		//	vd untouched: still the canary
	vse8.v	v8, (t1)
	li	t0, F0 + 0xA00
	li	t1, 16
1:	lbu	t2, 0(t0)
	li	t3, 0xEE
	bne	t2, t3, fail_i
	addi	t0, t0, 1
	addi	t1, t1, -1
	bnez	t1, 1b
	li	t0, STRAPS_VAR		//	demand-map + sret restart
	sd	zero, 0(t0)
	li	t0, SMODE_VAR
	li	t1, 1
	sd	t1, 0(t0)
	li	t1, VR2
	vle8.v	v8, (t1)		//	faults once, S maps VR2 -> F2, retries
	li	t0, SMODE_VAR
	sd	zero, 0(t0)
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_i
	li	t1, V0 + 0x900		//	loaded data = F2 pattern
	vse8.v	v8, (t1)
	li	a0, F0 + 0x900
	li	a1, F2
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_i

	//	---- J: U-mode vector memory through U PTEs. Enter a low-VA
	//	U-executable page, run unit-stride/strided/indexed vector load+store
	//	forms through U data aliases, and return via delegated U ecall. ----
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t0, SCAUSE_VAR
	sd	zero, 0(t0)
	li	t0, STVAL_VAR
	sd	zero, 0(t0)
	li	t0, SEPC_VAR
	sd	zero, 0(t0)
	li	t0, SMODE_VAR
	li	t1, 2
	sd	t1, 0(t0)
	li	t0, UCODE_VA
	csrw	sepc, t0
	csrr	t0, sstatus
	li	t1, ~(1 << 8)		//	SPP = U for the test entry
	and	t0, t0, t1
	li	t1, (1 << 5)		//	SPIE = 1
	or	t0, t0, t1
	csrw	sstatus, t0
	sret
s_after_u:
	li	t0, SMODE_VAR
	sd	zero, 0(t0)
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_j
	li	t0, SCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 8
	bne	t1, t2, fail_j		//	U ecall
	li	t0, STVAL_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_j
	li	t0, SEPC_VAR
	ld	t1, 0(t0)
	la	t2, u_ecall
	li	t3, UCODE_PHYS
	sub	t2, t2, t3
	li	t3, UCODE_VA
	add	t2, t2, t3
	bne	t1, t2, fail_j

	li	a0, F0 + 0xC00		//	U vle8/vse8 spanning UV0->UV1
	li	a1, F0 + 0xFF0
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_j
	li	a0, F0 + 0xC10
	li	a1, F1
	li	a2, 16
	jal	ra, cmpn
	bnez	a0, fail_j

	li	a0, F0 + 0xC40		//	U vlse16/vsse16
	li	a1, F0 + 0xFFC
	li	a2, 2
	jal	ra, cmpn
	bnez	a0, fail_j
	li	a0, F0 + 0xC44
	li	a1, F1 + 0x004
	li	a2, 2
	jal	ra, cmpn
	bnez	a0, fail_j
	li	a0, F0 + 0xC48
	li	a1, F1 + 0x00C
	li	a2, 2
	jal	ra, cmpn
	bnez	a0, fail_j
	li	a0, F0 + 0xC4C
	li	a1, F1 + 0x014
	li	a2, 2
	jal	ra, cmpn
	bnez	a0, fail_j

	li	t0, 0			//	U vluxei32 result at F0+0xD20
	li	t1, F0 + 0xD20
1:	lw	t2, 0(t1)
	li	t3, 28
	slli	t4, t0, 2
	sub	t3, t3, t4
	li	t5, F0 + 0xE00
	add	t5, t5, t3
	lw	t6, 0(t5)
	bne	t2, t6, fail_j
	addi	t1, t1, 4
	addi	t0, t0, 1
	li	t3, 8
	bne	t0, t3, 1b

	li	t0, 0			//	U vsuxei32 scattered at F0+0xD80
1:	li	t3, 28
	slli	t4, t0, 2
	sub	t3, t3, t4
	li	t5, F0 + 0xD80
	add	t5, t5, t3
	lw	t2, 0(t5)
	li	t6, F0 + 0xE80
	add	t6, t6, t4
	lw	t1, 0(t6)
	bne	t2, t1, fail_j
	addi	t0, t0, 1
	li	t3, 8
	bne	t0, t3, 1b

	//	================================================================
	//	K-O: permission matrix. Page faults are delegated to S (set in
	//	phase I), so faults land in s_vtrap (SMODE 0 = record + skip):
	//	STRAPS_VAR counts, SCAUSE_VAR/STVAL_VAR record. New pages are
	//	patched into L0 at runtime (like the demand-map path) + sfence.
	//	================================================================

	//	---- K: load-only page -> vector STORE faults (cause 15) ----
	li	t0, L0T + 12*8		//	VRO = 0xC000 -> F2, R-only
	li	t1, LEAF_RO
	sd	t1, 0(t0)
	sfence.vma
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xC000
	vle8.v	v8, (t1)		//	load from R page: must succeed
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_k
	li	t1, 0xC000
	vse8.v	v8, (t1)		//	store to R-only page: cause 15
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_k
	li	t0, SCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 15
	bne	t1, t2, fail_k
	li	t0, STVAL_VAR
	ld	t1, 0(t0)
	li	t2, 0xC000
	bne	t1, t2, fail_k
	csrw	vstart, zero

	//	---- L: SUM -- S access to a U-page (UV0=0xA000) ----
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t2, (1 << 18)		//	SUM
	csrc	sstatus, t2		//	SUM = 0
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xA000
	vle8.v	v8, (t1)		//	S load from U page, SUM=0 -> fault 13
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_l
	li	t0, SCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 13
	bne	t1, t2, fail_l
	csrw	vstart, zero
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t2, (1 << 18)
	csrs	sstatus, t2		//	SUM = 1
	li	t1, 0xA000
	vle8.v	v8, (t1)		//	now succeeds
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_l
	li	t2, (1 << 18)
	csrc	sstatus, t2		//	restore SUM = 0

	//	---- M: MXR -- load from an execute-only page (no R) ----
	li	t0, L0T + 13*8		//	VXO = 0xD000 -> F2, X-only
	li	t1, LEAF_XO
	sd	t1, 0(t0)
	sfence.vma
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t2, (1 << 19)		//	MXR
	csrc	sstatus, t2		//	MXR = 0
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xD000
	vle8.v	v8, (t1)		//	X-only, no MXR -> fault 13
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_m
	li	t0, SCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 13
	bne	t1, t2, fail_m
	csrw	vstart, zero
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t2, (1 << 19)
	csrs	sstatus, t2		//	MXR = 1
	li	t1, 0xD000
	vle8.v	v8, (t1)		//	X readable now -> succeeds
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_m
	li	t2, (1 << 19)
	csrc	sstatus, t2		//	restore MXR = 0

	//	---- N: Svadu -- store to W,D=0 page sets A+D in the PTE, no fault ----
	li	t0, L0T + 14*8		//	VWND = 0xE000 -> F2, R|W|A (D=0)
	li	t1, LEAF_WND
	sd	t1, 0(t0)
	sfence.vma
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xE000
	vse8.v	v8, (t1)		//	store -> HW A/D writeback (no fault)
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	bnez	t1, fail_n
	li	t0, L0T + 14*8		//	re-read the PTE from memory
	ld	t1, 0(t0)
	li	t2, PTE_D
	and	t3, t1, t2
	beqz	t3, fail_n		//	D must now be set
	li	t2, PTE_A
	and	t3, t1, t2
	beqz	t3, fail_n		//	A must now be set

	//	---- O: invalid PTE (V=0) -> vector load faults 13 ----
	li	t0, L0T + 15*8		//	VINV = 0xF000 -> 0 (invalid)
	sd	zero, 0(t0)
	sfence.vma
	li	t0, STRAPS_VAR
	sd	zero, 0(t0)
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, 0xF000
	vle8.v	v8, (t1)		//	V=0 -> fault 13
	li	t0, STRAPS_VAR
	ld	t1, 0(t0)
	li	t2, 1
	bne	t1, t2, fail_o
	li	t0, SCAUSE_VAR
	ld	t1, 0(t0)
	li	t2, 13
	bne	t1, t2, fail_o
	csrw	vstart, zero

	li	t0, 1			//	exit 0: all pass
	j	write_tohost
fail_a:	li	t0, (2 << 1) | 1
	j	write_tohost
fail_b:	li	t0, (3 << 1) | 1
	j	write_tohost
fail_c:	li	t0, (4 << 1) | 1
	j	write_tohost
fail_d:	li	t0, (5 << 1) | 1
	j	write_tohost
fail_e:	li	t0, (6 << 1) | 1
	j	write_tohost
fail_f:	li	t0, (7 << 1) | 1
	j	write_tohost
fail_g:	li	t0, (8 << 1) | 1
	j	write_tohost
fail_h:	li	t0, (9 << 1) | 1
	j	write_tohost
fail_i:	li	t0, (10 << 1) | 1
	j	write_tohost
fail_j:	li	t0, (11 << 1) | 1
	j	write_tohost
fail_k:	li	t0, (12 << 1) | 1
	j	write_tohost
fail_l:	li	t0, (13 << 1) | 1
	j	write_tohost
fail_m:	li	t0, (14 << 1) | 1
	j	write_tohost
fail_n:	li	t0, (15 << 1) | 1
	j	write_tohost
fail_o:	li	t0, (16 << 1) | 1
write_tohost:
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

//	cmpn: a0=p, a1=q, a2=n -> a0 = 0 iff equal. Clobbers t0-t2. Leaf.
cmpn:
1:	lbu	t0, 0(a0)
	lbu	t1, 0(a1)
	bne	t0, t1, 2f
	addi	a0, a0, 1
	addi	a1, a1, 1
	addi	a2, a2, -1
	bnez	a2, 1b
	li	a0, 0
	ret
2:	li	a0, 1
	ret

//	====================================================================
//	U-mode vector code. This section is linked at UCODE_PHYS but mapped at
//	UCODE_VA; keep it self-contained and avoid absolute label loads.
//	====================================================================
	.section .ucode, "ax"
	.balign 4
u_phase:
	li	t0, 32
	vsetvli	t0, t0, e8, m1, tu, mu
	li	t1, UV0 + 0xFF0
	vle8.v	v8, (t1)
	li	t1, UV0 + 0xC00
	vse8.v	v8, (t1)

	li	t0, 4
	vsetvli	t0, t0, e16, m1, tu, mu
	li	t1, UV0 + 0xFFC
	li	t2, 8
	vlse16.v v10, (t1), t2
	li	t1, UV0 + 0xC40
	li	t2, 4
	vsse16.v v10, (t1), t2

	li	t1, UV0 + 0xD00		//	indices: 28,24,...,0
	li	t2, 28
	sw	t2, 0(t1)
	li	t2, 24
	sw	t2, 4(t1)
	li	t2, 20
	sw	t2, 8(t1)
	li	t2, 16
	sw	t2, 12(t1)
	li	t2, 12
	sw	t2, 16(t1)
	li	t2, 8
	sw	t2, 20(t1)
	li	t2, 4
	sw	t2, 24(t1)
	sw	zero, 28(t1)

	li	t0, 8
	vsetvli	t0, t0, e32, m1, tu, mu
	vle32.v	v4, (t1)
	li	t1, UV0 + 0xE00
	vluxei32.v v12, (t1), v4
	li	t1, UV0 + 0xD20
	vse32.v v12, (t1)
	li	t1, UV0 + 0xE80
	vle32.v	v8, (t1)
	li	t1, UV0 + 0xD80
	vsuxei32.v v8, (t1), v4
u_ecall:
	ecall
1:	j	1b

//	====================================================================
//	Sv39 tables. root[0] -> L1 -> L0; root[2] = identity for 0x8000_0000.
//	L0[4]=F0 [5]=F1 [6]=unmapped [7]=unmapped (demand-mapped to F2),
//	[8]=unmapped (S-demand-mapped), [9]=U code, [10]=U F0, [11]=U F1.
//	====================================================================
	.section .root, "a"
	.quad	PTR_L1			//	[0]
	.quad	0			//	[1]
	.quad	IDENT2			//	[2]

	.section .l1, "a"
	.quad	PTR_L0			//	[0]

	.section .l0, "aw"
	.rept	4
	.quad	0			//	[0..3]
	.endr
	.quad	LEAF_F0			//	[4]
	.quad	LEAF_F1			//	[5]
	.quad	0			//	[6]  VF: never mapped
	.quad	0			//	[7]  VR: demand-mapped by m_trap
	.quad	0			//	[8]  VR2: demand-mapped by s_vtrap (phase I)
	.quad	LEAF_UCODE		//	[9]  UCODE_VA -> UCODE_PHYS
	.quad	LEAF_UF0		//	[10] UV0 -> F0 (U data alias)
	.quad	LEAF_UF1		//	[11] UV1 -> F1 (U data alias)

	.section .f0, "aw"
	.space	4096
	.section .f1, "aw"
	.space	4096
	.section .f2, "aw"
	.space	4096
