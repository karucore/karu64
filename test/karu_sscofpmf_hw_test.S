//	karu_sscofpmf_hw_test.S
//	Directed test for Sscofpmf 3b -- HARDWARE counter overflow + per-privilege inhibit
//	(built with KARU_SSCOFPMF; karu64-only -- spike has no HW overflow). The testbench
//	wires hpm_events[1] = retire pulse, so mhpmevent3 = event 1 counts retired
//	instructions and a preloaded counter can be made to wrap.
//	  Part I  (M): overflow -> sets OF + mip[13] -> LCOFI taken once; the free-running
//	               counter keeps counting with OF set (event match ignores control
//	               bits); no repeated LCOFI; a CSR write to max alone does NOT overflow.
//	  Part II (M/S/U): MINH/SINH/UINH freeze the counter in the matching privilege.
//	exit 0 = pass.

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
	li	t5, 11
	beq	t6, t5, m_ret		//	ecall from M
	li	t5, 9
	beq	t6, t5, m_ret		//	ecall from S
	li	t5, 8
	beq	t6, t5, m_ret		//	ecall from U
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
	csrw	mstatus, t1
	mret

done:
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

	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
