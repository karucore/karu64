//	karu_sscofpmf_hw_test.S
//	Directed test for Sscofpmf 3b -- HARDWARE counter overflow + per-privilege inhibit
//	(built with KARU_SSCOFPMF; karu64-only -- spike has no HW overflow). The testbench
//	wires hpm_events[1] = retire pulse, so mhpmevent3 = event 1 counts retired
//	instructions and a preloaded counter can be made to wrap.
//	  Part I  (M): overflow -> sets OF + mip[13] -> LCOFI taken once; the free-running
//	               counter keeps counting with OF set (event match ignores control
//	               bits); no repeated LCOFI; a CSR write to max alone does NOT overflow.
//	  Part II (M/S/U): MINH/SINH/UINH freeze the counter in the matching privilege.
//	  SSCOFPMF_H_GUEST=1 adds 15 cases: exact VS/VU retire counts, opposite
//	  guest filters, MPRV+MPV nominal-mode counting, CSR-write non-overflow,
//	  and guest hardware overflow delivered to HS with scountovf/SPV checks.
//	  Requires KARU_H + KARU_SSCOFPMF. Case IDs 101..104,111..114,120,131..136
//	  are returned on failure.
//	exit 0 = pass.

#ifndef SSCOFPMF_H_GUEST
#define SSCOFPMF_H_GUEST 0
#endif

	.equ TOHOST,            0x80001000
	.equ CSR_MHPMEVENT3,    0x323
	.equ CSR_MHPMCOUNTER3,  0xB03
	.equ CSR_MCOUNTINHIBIT, 0x320
	.equ CSR_SCOUNTOVF,     0xDA0
	.equ CSR_MIE,           0x304
	.equ CSR_MIP,           0x344
	.equ CSR_MIDELEG,       0x303

	.section .text.boot,"ax"
	.globl _start
	.option norvc
_start:
	la	t0, m_handler
	csrw	mtvec, t0
	li	s1, 0			//	error accumulator
#if SSCOFPMF_H_GUEST
	li	s0, 0			//	zero during the legacy M/S/U cases
#endif

	//	=== Part I.1: hardware overflow -> OF + LCOFI to M ===
	csrw	CSR_MIDELEG, x0		//	LCOFI -> M
	li	t0, 1
	slli	t0, t0, 13
	csrw	CSR_MIE, t0		//	LCOFIE
	csrr	t0, mstatus
	ori	t0, t0, (1 << 3)	//	MIE
	csrw	mstatus, t0
	li	s2, 0			//	lcofi_count
	li	t0, (1 << 3)
	csrw	CSR_MCOUNTINHIBIT, t0	//	freeze counter3 for the preload
	li	t0, 1
	csrw	CSR_MHPMEVENT3, t0	//	event 1 = retire
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0	//	preload all-ones
	csrw	CSR_MCOUNTINHIBIT, x0	//	unfreeze -> next retire wraps it
	nop
	nop
	nop
	li	t4, 1
	beq	s2, t4, i1_ok
	ori	s1, s1, 1		//	LCOFI not taken exactly once
i1_ok:
	csrr	t0, CSR_SCOUNTOVF
	srli	t0, t0, 3
	andi	t0, t0, 1
	bnez	t0, i2
	ori	s1, s1, 2		//	OF (scountovf bit 3) not set by HW overflow
i2:
	//	=== Part I.2: counter keeps counting with OF set; no repeated LCOFI ===
	csrr	s5, CSR_MHPMCOUNTER3	//	c0
	nop
	nop
	nop
	nop
	csrr	t0, CSR_MHPMCOUNTER3	//	c1
	bgtu	t0, s5, i2_ok
	ori	s1, s1, 4		//	counter did not advance with OF set (event match broke)
i2_ok:
	li	t4, 1
	beq	s2, t4, i2b		//	still exactly one LCOFI -> no repeat from free-running
	ori	s1, s1, 8
i2b:
	//	=== Part I.2b: a wrap while OF=1 must NOT request a new LCOFI (OF disables it) ===
	//	OF is still set from I.1 (the handler cleared mip[13] only). Wrap the counter
	//	again and assert no new interrupt -- OF doubles as the overflow-int-disable.
	li	t0, (1 << 3)
	csrw	CSR_MCOUNTINHIBIT, t0	//	freeze for the preload
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0	//	preload max (mhpmevent3.OF still 1, event still 1)
	csrw	CSR_MCOUNTINHIBIT, x0
	nop
	nop
	nop				//	wraps again, but OF=1 -> no LCOFI
	li	t4, 1
	beq	s2, t4, i3		//	lcofi_count must STILL be exactly 1
	li	t5, 2048		//	(ori imm max is 2047)
	or	s1, s1, t5
i3:
	//	=== Part I.3: a CSR write to max (no event) must NOT cause overflow ===
	csrw	CSR_MHPMEVENT3, x0	//	event = NONE (no counting); also clears OF
	csrw	CSR_MIP, x0
	li	s2, 0
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0	//	CSR-write the counter to max
	nop
	nop
	nop
	bnez	s2, i3_bad		//	no LCOFI from a CSR write
	csrr	t0, CSR_SCOUNTOVF
	srli	t0, t0, 3
	andi	t0, t0, 1
	beqz	t0, part2		//	OF must stay 0
i3_bad:
	ori	s1, s1, 16
part2:
	//	=== Part I.4: active event coincident with counter write is not a wrap ===
	//	The counter write is the update for that instruction.  Its retire event
	//	must not also increment the old all-ones value and synthesize an overflow.
	csrw	CSR_MIE, x0		//	leave a bad LCOFIP observable instead of taking it
	csrw	CSR_MIP, x0
	csrw	CSR_MHPMEVENT3, x0
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0
	li	t0, 1
	csrw	CSR_MHPMEVENT3, t0	//	event 1 = retire
	csrw	CSR_MHPMCOUNTER3, x0	//	coincident retire must be suppressed
	csrw	CSR_MHPMEVENT3, x0	//	stop counting and clear any bad OF
	csrr	t0, CSR_MIP
	li	t1, 0x2000
	and	t0, t0, t1
	beqz	t0, i4_ok
	li	t1, 4096
	or	s1, s1, t1
i4_ok:
	csrw	CSR_MIP, x0

	//	=== Part II.M: MINH freezes counting in M (tight bracketed window) ===
	csrw	CSR_MIP, x0
	li	s2, 0
	li	t0, 1
	li	t1, 1
	slli	t1, t1, 62		//	MINH
	or	t0, t0, t1		//	event1 | MINH
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, x0	//	preload 0
	csrr	s5, CSR_MHPMCOUNTER3	//	c0
	nop
	nop
	nop
	nop
	csrr	t0, CSR_MHPMCOUNTER3	//	c1
	beq	t0, s5, iim_count	//	MINH set -> frozen (c1 == c0)
	ori	s1, s1, 32
iim_count:
	li	t0, 1
	csrw	CSR_MHPMEVENT3, t0	//	event1, no inhibit
	csrr	s5, CSR_MHPMCOUNTER3	//	c0
	nop
	nop
	nop
	nop
	csrr	t0, CSR_MHPMCOUNTER3	//	c1
	bgtu	t0, s5, iiu_4a		//	no inhibit -> counts (c1 > c0)
	ori	s1, s1, 64
iiu_4a:
	//	=== Part II.U: UINH freezes counting in U (MINH set so M does not pollute) ===
	li	t0, 1
	li	t1, 1
	slli	t1, t1, 62		//	MINH
	or	t0, t0, t1		//	event1 | MINH (UINH clear)
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, x0	//	preload 0
	la	s4, iiu_4a_chk
	li	t1, 0			//	MPP = U
	j	enter_p
iiu_4a_chk:
	csrr	t0, CSR_MHPMCOUNTER3
	bnez	t0, iiu_4b		//	UINH clear -> U counted
	ori	s1, s1, 128
iiu_4b:
	li	t0, 1
	li	t1, 1
	slli	t1, t1, 62		//	MINH
	li	t2, 1
	slli	t2, t2, 60		//	UINH
	or	t0, t0, t1
	or	t0, t0, t2		//	event1 | MINH | UINH
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, x0
	la	s4, iiu_4b_chk
	li	t1, 0			//	MPP = U
	j	enter_p
iiu_4b_chk:
	csrr	t0, CSR_MHPMCOUNTER3
	beqz	t0, iis_5a		//	UINH set -> U frozen
	ori	s1, s1, 256
iis_5a:
	//	=== Part II.S: SINH freezes counting in S ===
	li	t0, 1
	li	t1, 1
	slli	t1, t1, 62		//	MINH
	or	t0, t0, t1		//	event1 | MINH (SINH clear)
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, x0
	la	s4, iis_5a_chk
	li	t1, 1			//	MPP = S
	j	enter_p
iis_5a_chk:
	csrr	t0, CSR_MHPMCOUNTER3
	bnez	t0, iis_5b		//	SINH clear -> S counted
	ori	s1, s1, 512
iis_5b:
	li	t0, 1
	li	t1, 1
	slli	t1, t1, 62		//	MINH
	li	t2, 1
	slli	t2, t2, 61		//	SINH
	or	t0, t0, t1
	or	t0, t0, t2		//	event1 | MINH | SINH
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, x0
	la	s4, iis_5b_chk
	li	t1, 1			//	MPP = S
	j	enter_p
iis_5b_chk:
	csrr	t0, CSR_MHPMCOUNTER3
	beqz	t0, done		//	SINH set -> S frozen
	ori	s1, s1, 1024
	j	done

	//	enter the target privilege (t1=0 U / 1 S) at p_measure; s4 = M return addr.
enter_p:
	csrr	t0, mstatus
	li	t2, (3 << 11)
	not	t2, t2
	and	t0, t0, t2		//	clear MPP
	slli	t1, t1, 11
	or	t0, t0, t1		//	MPP = target
	csrw	mstatus, t0
	la	t0, p_measure
	csrw	mepc, t0
	mret
p_measure:
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop			//	8 retires in the target privilege
	ecall			//	-> M handler -> resume at s4

	.align 2
m_handler:
	csrr	t6, mcause
	bltz	t6, m_int		//	bit 63 -> interrupt
#if SSCOFPMF_H_GUEST
	li	t5, 10
	beq	t6, t5, m_ret		//	ecall from VS
#endif
	li	t5, 11
	beq	t6, t5, m_ret		//	ecall from M
	li	t5, 9
	beq	t6, t5, m_ret		//	ecall from S
	li	t5, 8
	beq	t6, t5, m_ret		//	ecall from U
#if SSCOFPMF_H_GUEST
	bnez	s0, h_fail
#endif
	li	t0, (9 << 1) | 1	//	unexpected exception
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
m_int:
	andi	t5, t6, 63
	li	t4, 13
	bne	t5, t4, m_int_bad
	addi	s2, s2, 1		//	lcofi_count++
	csrw	CSR_MIP, x0		//	clear LCOFIP only (leave OF set) -> tests no-repeat
	mret
m_int_bad:
	li	t0, (5 << 1) | 1	//	wrong interrupt cause
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
m_ret:
	csrw	mepc, s4
	csrr	t1, mstatus
	li	t2, (3 << 11)
	or	t1, t1, t2		//	MPP = M (return to M)
#if SSCOFPMF_H_GUEST
	li	t2, 0x8000020000		//	clear MPV/MPRV before the M continuation
	not	t2, t2
	and	t1, t1, t2
#endif
	csrw	mstatus, t1
	mret

done:
#if SSCOFPMF_H_GUEST
	bnez	s1, fail
	j	h_guest_start
h_guest_done:
#endif
	bnez	s1, fail
	li	t0, 1			//	(0<<1)|1 -> exit 0 (pass)
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
fail:
	slli	t0, s1, 1
	ori	t0, t0, 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

#if SSCOFPMF_H_GUEST
	.globl sscofpmf_h_cases
	.equ sscofpmf_h_cases, 21

	// All setup/check instructions execute in inhibited M mode. The shared
	// p_measure body retires eight NOPs; ECALL does not retire, and MRET's
	// retirement belongs to its M-mode origin, not its guest destination.
	.macro H_FILTER id, mode, mask, expected
	li	s0, \id
	li	t0, (\mask | 1)
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, zero
	la	s4, h_filter_done_\@
	li	t1, \mode
	j	h_enter_guest
h_filter_done_\@:
	csrr	t0, CSR_MHPMCOUNTER3
	li	t1, \expected
	bne	t0, t1, h_fail
	.endm

	// The bracket contains the first CSR read, eight NOPs and one actual
	// MPRV+MPV load: ten retire events, all nominally M regardless of MPP.
	.macro H_MPRV id, mode, mask, expected
	li	s0, \id
	li	t0, (\mask | 1)
	csrw	CSR_MHPMEVENT3, t0
	csrw	CSR_MHPMCOUNTER3, zero
	la	t3, h_load_data
	li	t2, 0x8000021800
	csrc	mstatus, t2
	li	t2, (0x8000020000 | (\mode << 11))
	csrs	mstatus, t2
	csrr	s5, CSR_MHPMCOUNTER3
	.rept 8
	nop
	.endr
	ld	t2, 0(t3)
	csrr	t0, CSR_MHPMCOUNTER3
	sub	t0, t0, s5
	li	t2, 0x8000020000
	csrc	mstatus, t2
	li	t1, \expected
	bne	t0, t1, h_fail
	.endm

	.macro H_OVERFLOW id, mode, mask, rearm, irq_count
	li	s0, \id
	li	s9, \mode
	.if \rearm
	li	t0, (\mask | 1)
	csrw	CSR_MHPMEVENT3, t0	//	clear OF, keep only target guest counting
	.endif
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0
	// No M-mode instruction can overflow this guest-only counter, including
	// writes to the all-ones preload or writes that rearm mhpmevent.OF.
	csrr	t0, CSR_MIP
	li	t1, 0x2000
	and	t0, t0, t1
	bnez	t0, h_fail
	csrr	t0, CSR_SCOUNTOVF
	.if \rearm
	bnez	t0, h_fail
	.else
	li	t1, 8
	bne	t0, t1, h_fail
	.endif
	la	s4, h_overflow_done_\@
	li	t1, \mode
	j	h_enter_guest
h_overflow_done_\@:
	li	t0, \irq_count
	bne	s8, t0, h_fail
	csrr	t0, CSR_MHPMCOUNTER3
	li	t1, 7			//	all-ones + eight guest retires
	bne	t0, t1, h_fail
	csrr	t0, CSR_SCOUNTOVF
	li	t1, 8
	bne	t0, t1, h_fail
	csrr	t0, CSR_MIP
	li	t1, 0x2000
	and	t0, t0, t1
	bnez	t0, h_fail
	.endm

	// Shlcofideleg shares sip.LCOFIP (not AIA's hvip injection). Test
	// software pending and a real guest-only counter wrap at both VS and VU.
	.macro H_DELEGATE id, mode, delegate, hardware, mask
	li	s0, \id
	li	s7, \delegate
	li	s8, 0
	csrw	CSR_MHPMEVENT3, zero
	csrw	CSR_MIP, zero
	li	t0, (\delegate << 13)
	csrw	0x603, t0
	li	t0, 0x2000
	csrw	CSR_MIE, t0
	csrw	0x204, t0		// vsie.LCOFIE when delegated
	li	t0, 2
	csrw	0x200, t0		// vsstatus.SIE
	.if \hardware
	li	t0, (\mask | 1)
	csrw	CSR_MHPMEVENT3, t0
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0
	.else
	li	t0, 0x2000
	csrs	sip, t0
	.endif
	la	s4, h_delegate_done_\@
	li	t1, \mode
	j	h_enter_guest
h_delegate_done_\@:
	li	t0, 1
	bne	s8, t0, h_fail
	csrr	t0, CSR_MIP
	li	t1, 0x2000
	and	t0, t0, t1
	bnez	t0, h_fail
	.if \hardware
	csrr	t0, CSR_SCOUNTOVF
	li	t1, 8
	bne	t0, t1, h_fail
	.endif
	.endm

	.balign 4
h_guest_start:
	csrw	CSR_MIE, zero
	csrw	CSR_MIP, zero
	csrw	CSR_MCOUNTINHIBIT, zero
	csrw	medeleg, zero
	csrw	0x602, zero		//	hedeleg: guest ECALL returns to M
	csrw	0x603, zero		//	hideleg
	csrw	satp, zero
	csrw	0x280, zero		//	vsatp Bare
	csrw	0x680, zero		//	hgatp Bare

	// Opposite VSINH/VUINH values; MINH/SINH/UINH remain set throughout.
	H_FILTER 101, 1, 0x7400000000000000, 8
	H_FILTER 102, 1, 0x7800000000000000, 0
	H_FILTER 103, 0, 0x7800000000000000, 8
	H_FILTER 104, 0, 0x7400000000000000, 0

	// Effective VS/VU memory privilege must not replace nominal M filtering.
	H_MPRV 111, 1, 0x3c00000000000000, 10
	H_MPRV 112, 1, 0x4000000000000000, 0
	H_MPRV 113, 0, 0x3c00000000000000, 10
	H_MPRV 114, 0, 0x4000000000000000, 0

	// CSR-written OF is visible, but neither that write nor a counter write
	// requests LCOFI. Event 1 is selected, with every execution mode inhibited.
	li	s0, 120
	csrw	CSR_MIP, zero
	li	t0, 0xfc00000000000001
	csrw	CSR_MHPMEVENT3, t0
	li	t0, -1
	csrw	CSR_MHPMCOUNTER3, t0
	.rept 4
	nop
	.endr
	csrr	t0, CSR_MIP
	li	t1, 0x2000
	and	t0, t0, t1
	bnez	t0, h_fail
	csrr	t0, CSR_SCOUNTOVF
	li	t1, 8
	bne	t0, t1, h_fail
	csrr	t0, CSR_MHPMCOUNTER3
	li	t1, -1
	bne	t0, t1, h_fail
	li	t0, 0x7c00000000000001
	csrw	CSR_MHPMEVENT3, t0
	csrr	t0, CSR_SCOUNTOVF
	bnez	t0, h_fail
	csrr	t0, CSR_MIP
	li	t1, 0x2000
	and	t0, t0, t1
	bnez	t0, h_fail

	// Delegate actual guest-generated overflows to HS. The HS handler is
	// itself inhibited, acknowledges LCOFIP without clearing OF, and SRETs.
	la	t0, h_hs_handler
	csrw	stvec, t0
	li	t0, 8
	csrw	mcounteren, t0		//	HS scountovf bit 3 is visible
	li	t0, 0x2000
	csrw	CSR_MIDELEG, t0
	csrw	CSR_MIE, t0
	li	s8, 0
	H_OVERFLOW 131, 1, 0x7400000000000000, 1, 1
	H_OVERFLOW 132, 1, 0x7400000000000000, 0, 1
	H_OVERFLOW 133, 1, 0x7400000000000000, 1, 2
	H_OVERFLOW 134, 0, 0x7800000000000000, 1, 3
	H_OVERFLOW 135, 0, 0x7800000000000000, 0, 3
	H_OVERFLOW 136, 0, 0x7800000000000000, 1, 4
	la	t0, h_delegate_hs
	csrw	stvec, t0
	la	t0, h_delegate_vs
	csrw	0x205, t0
	H_DELEGATE 141, 1, 1, 0, 0
	H_DELEGATE 142, 0, 1, 0, 0
	H_DELEGATE 143, 1, 0, 0, 0
	H_DELEGATE 144, 0, 0, 0, 0
	H_DELEGATE 145, 1, 1, 1, 0x7400000000000000
	H_DELEGATE 146, 0, 1, 1, 0x7800000000000000
	csrw	CSR_MIE, zero
	csrw	CSR_MHPMEVENT3, zero
	j	h_guest_done

h_enter_guest:
	csrr	t0, mstatus
	li	t2, 0x8000021800		//	MPV/MPRV/MPP
	not	t2, t2
	and	t0, t0, t2
	li	t2, 0x8000000000		//	MPV
	or	t0, t0, t2
	slli	t1, t1, 11
	or	t0, t0, t1
	csrw	mstatus, t0
	la	t0, p_measure
	csrw	mepc, t0
	mret

	.balign 4
h_hs_handler:
	csrr	t0, scause
	li	t1, 0x800000000000000d
	bne	t0, t1, h_fail
	csrr	t0, 0x600		//	hstatus: SPV and source VS/VU in SPVP
	andi	t0, t0, 0x180
	slli	t1, s9, 8
	ori	t1, t1, 0x80
	bne	t0, t1, h_fail
	csrr	t0, CSR_SCOUNTOVF
	li	t1, 8
	bne	t0, t1, h_fail
	csrr	t0, sip
	li	t1, 0x2000
	and	t0, t0, t1
	beqz	t0, h_fail
	csrc	sip, t1			//	acknowledge request; retain sticky OF
	addi	s8, s8, 1
	sret

	.balign 4
h_delegate_hs:
	bnez	s7, h_fail
	csrr	t0, 0x600		// HS must have interrupted a guest
	andi	t0, t0, 0x80
	beqz	t0, h_fail
	j	h_delegate_ack
	.balign 4
h_delegate_vs:
	li	t0, 1
	bne	s7, t0, h_fail
	// Reading hstatus here must be illegal: execution is genuinely in VS.
	// The distinct VS trap vector and banked scause/sip verify that route.
h_delegate_ack:
	csrr	t0, scause
	li	t1, 0x800000000000000d
	bne	t0, t1, h_fail
	csrr	t0, sip
	li	t1, 0x2000
	and	t0, t0, t1
	beqz	t0, h_fail
	csrc	sip, t1
	addi	s8, s8, 1
	sret

h_fail:
	slli	t0, s0, 1
	ori	t0, t0, 1
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b
	.balign 8
h_load_data:
	.dword 0x7356436f66504d46
#endif

	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
