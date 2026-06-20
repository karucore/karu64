//	karu_xpage_test.S
//	Directed test for the misaligned-cross-page SCALAR access bug
//	(doc/fpga.md "second candidate";
//	 doc/fpga.md Update 10).
//
//	A scalar load/store that is misaligned across an 8-byte beat AND straddles
//	a 4 KiB PAGE boundary is split by karu_lsu into two beats whose addresses
//	are computed in PHYSICAL space as (PA & ~7) + 8 -- the effective VA is
//	translated only ONCE (karu64.v:1008 + :1263; karu_lsu.v:271 read / :332
//	store). So beat-2 lands on the physically-adjacent frame F_lo+1 instead of
//	translate(VA + page) = F_hi. Bare-metal (M-mode, VA == PA) is correct by
//	construction, which is why the existing M-mode suites never see it; this
//	test runs in S-mode with Sv39 ON and two VA-adjacent pages mapped to
//	NON-adjacent physical frames.
//
//	The SAME ELF on spike (golden, which re-translates beat-2) PASSes (exit 0).
//	On the buggy karu64 it FAILs: the store's high bytes land in F_adj (not
//	F_hi), and the load's high bytes come from F_adj (not F_hi).
//
//	Frames (F_hi is deliberately NOT F_lo+1):
//	  F_LO  = 0x8000_5000   <- VA_LO = 0x4000   (beat-1 frame; correct on both)
//	  F_ADJ = 0x8000_6000   =  F_LO + 1, unmapped from the low-VA alias
//	                              (buggy beat-2 target)
//	  F_HI  = 0x8000_7000   <- VA_HI = 0x5000   (beat-2 SHOULD land here)
//	A 1 GiB identity leaf (region 2, 0x8000_0000) maps code/tohost and lets the
//	S-mode driver inspect all three physical frames directly.
//
//	Exit code is a BITMASK of failed checks (0 = all pass). The harness prints
//	"[HTIF] exit <code>"; spike returns the same code.
//	  bit 0 (0x01)  STORE beat-1 (low half) wrong            -- sanity
//	  bit 1 (0x02)  STORE beat-2 hit the ADJACENT frame      -- THE BUG (store)
//	  bit 2 (0x04)  STORE beat-2 missing from F_hi           -- corroborates 1
//	  bit 3 (0x08)  LOAD  beat-2 came from the WRONG frame   -- THE BUG (load)
//	  bit 4 (0x10)  LOAD  beat-1 (low half) wrong            -- sanity
//	  0x40          unexpected trap (mcause stashed @ MCAUSE_VAR)
//	Expected: spike -> 0 ; buggy karu64 -> 0x0E (bits 1,2,3).

	.equ	TOHOST,		0x80001000
	.equ	MCAUSE_VAR,	0x80001010

	.globl	tohost
	.globl	fromhost
	.set	tohost,   TOHOST
	.set	fromhost, 0x80001030

	.equ	ROOT,	0x80002000
	.equ	L1T,	0x80003000
	.equ	L0T,	0x80004000
	.equ	F_LO,	0x80005000
	.equ	F_ADJ,	0x80006000
	.equ	F_HI,	0x80007000

	.equ	VA_LO,	0x4000		//	vpn0 = 4  -> L0[4]
	.equ	VA_HI,	0x5000		//	vpn0 = 5  -> L0[5]  (VA-adjacent to VA_LO)

	.equ	PTE_V,	0x01
	.equ	PTE_R,	0x02
	.equ	PTE_W,	0x04
	.equ	PTE_X,	0x08
	.equ	PTE_A,	0x40
	.equ	PTE_D,	0x80
	.equ	PTR_L1,	((L1T  >> 12) << 10) | PTE_V
	.equ	PTR_L0,	((L0T  >> 12) << 10) | PTE_V
	.equ	LEAF_LO,((F_LO >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_A|PTE_D
	.equ	LEAF_HI,((F_HI >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_A|PTE_D
	//	1 GiB identity leaf for region 2 (0x8000_0000): S RWX so code/tohost
	//	fetch+access work and the driver can read physical frames directly.
	.equ	IDENT2,	((0x80000000 >> 12) << 10) | PTE_V|PTE_R|PTE_W|PTE_X|PTE_A|PTE_D
	.equ	SATP0,	(8 << 60) | (ROOT >> 12)

	//	known data words (chosen distinct so the load test can tell the
	//	correct frame F_hi from the wrong frame F_adj):
	.equ	STVAL,	0x55667788	//	low word the STORE deposits in F_lo
	.equ	STHI,	0x11223344	//	high word the STORE should put in F_hi
	.equ	LDLO,	0xA4A3A2A1	//	low word the LOAD reads from F_lo
	.equ	LDHI,	0xB4B3B2B1	//	high word the LOAD should read from F_hi
	.equ	LDDEC,	0xC4C3C2C1	//	decoy in F_adj (what buggy karu64 reads)

//	OR (1<<\bit) into the failure accumulator s0 iff \a != \e (branchless).
	.macro	CHKEQ a, e, bit, tmp
	sub	\tmp, \a, \e
	snez	\tmp, \tmp
	slli	\tmp, \tmp, \bit
	or	s0, s0, \tmp
	.endm

//	====================================================================
//	M-mode entry: set a trap net, drop straight to S at s_driver.
//	(Page tables + zeroed frames are baked into the image by the linker.)
//	====================================================================
	.section .text.boot, "ax"
	.globl	_start
_start:
	la	t0, m_trap
	csrw	mtvec, t0
	//	MPP = S, then mret to s_driver
	csrr	t0, mstatus
	li	t1, ~(3 << 11)
	and	t0, t0, t1
	li	t1, (1 << 11)
	or	t0, t0, t1
	csrw	mstatus, t0
	la	t0, s_driver
	csrw	mepc, t0
	mret

//	M trap net: any unexpected trap records mcause and exits 0x40.
	.balign 4
m_trap:
	csrr	t1, mcause
	li	t0, MCAUSE_VAR
	sd	t1, 0(t0)
	li	a0, 0x40
	j	_exit

//	====================================================================
//	S-mode driver
//	====================================================================
	.balign 4
s_driver:
	li	t0, SATP0
	csrw	satp, t0
	sfence.vma
	li	s0, 0			//	failure-bit accumulator

	//	------------------------------------------------------------
	//	STORE test: an 8-byte store at VA_LO+0xFFC straddles the page
	//	boundary. Low 4 bytes -> F_lo (beat-1); high 4 bytes -> F_hi
	//	(beat-2, architecturally) but F_lo+1 = F_adj on buggy karu64.
	//	Frames start zeroed (sentinel 0), so a clobber is unambiguous.
	//	------------------------------------------------------------
	li	t1, VA_LO + 0xFFC
	li	t2, 0x1122334455667788		//	= {STHI, STVAL}
	sd	t2, 0(t1)

	//	(A,bit0) beat-1 low half must be in F_lo (correct on both).
	li	t1, F_LO + 0xFFC
	lwu	t3, 0(t1)
	li	t4, STVAL
	CHKEQ	t3, t4, 0, t6

	//	(B,bit1) F_adj must be UNTOUCHED. karu64's beat-2 lands here.
	li	t1, F_ADJ
	lwu	t3, 0(t1)
	li	t4, 0
	CHKEQ	t3, t4, 1, t6

	//	(C,bit2) F_hi must hold the high half. karu64 leaves it zero.
	li	t1, F_HI
	lwu	t3, 0(t1)
	li	t4, STHI
	CHKEQ	t3, t4, 2, t6

	//	------------------------------------------------------------
	//	LOAD test: prime the three frames with DISTINCT values via the
	//	identity map (aligned single-page writes -- correct on both),
	//	then a misaligned 8-byte load at VA_LO+0xFFC. High half must come
	//	from F_hi; buggy karu64 reads it from F_adj instead.
	//	------------------------------------------------------------
	li	t1, F_LO + 0xFFC
	li	t2, LDLO
	sw	t2, 0(t1)
	li	t1, F_HI
	li	t2, LDHI
	sw	t2, 0(t1)
	li	t1, F_ADJ
	li	t2, LDDEC
	sw	t2, 0(t1)

	li	t1, VA_LO + 0xFFC
	ld	t3, 0(t1)		//	t3 = {high32, low32}

	//	(D,bit3) high half must equal LDHI (from F_hi), not LDDEC (F_adj).
	srli	t4, t3, 32
	li	t5, LDHI
	CHKEQ	t4, t5, 3, t6

	//	(E,bit4) low half must equal LDLO (from F_lo); correct on both.
	slli	t4, t3, 32
	srli	t4, t4, 32
	li	t5, LDLO
	CHKEQ	t4, t5, 4, t6

	mv	a0, s0
	j	_exit

//	tohost exit: tohost = (code << 1) | 1.  code 0 = PASS.
	.balign 4
_exit:
	slli	a0, a0, 1
	ori	a0, a0, 1
	li	t0, TOHOST
	sd	a0, 0(t0)
1:	j	1b

//	====================================================================
//	Sv39 tables (baked into the image). root[0] -> L1 -> L0; root[2] =
//	1 GiB identity for 0x8000_0000. L0[4]=F_LO (VA 0x4000), [5]=F_HI
//	(VA 0x5000). F_adj (0x8000_6000) is intentionally NOT mapped through
//	the low-VA alias; only the identity leaf exposes it for inspection.
//	====================================================================
	.section .root, "a"
	.quad	PTR_L1			//	[0] -> L1
	.quad	0			//	[1]
	.quad	IDENT2			//	[2] identity 0x8000_0000 (code/tohost/frames)

	.section .l1, "a"
	.quad	PTR_L0			//	[0] -> L0

	.section .l0, "a"
	.rept	4
	.quad	0			//	[0..3]
	.endr
	.quad	LEAF_LO			//	[4] VA_LO 0x4000 -> F_LO
	.quad	LEAF_HI			//	[5] VA_HI 0x5000 -> F_HI

	//	data frames, zero-initialised in the image (sentinel = 0).
	.section .flo, "aw"
	.space	4096
	.section .fadj, "aw"
	.space	4096
	.section .fhi, "aw"
	.space	4096
