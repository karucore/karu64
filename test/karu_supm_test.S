//	karu_supm_test.S
//	Directed test for Supm (pointer masking): Smnpm (menvcfg.PMM -> S-mode) and
//	Ssnpm (senvcfg.PMM -> U-mode). Bare translation; the masking strips the top
//	PMLEN bits of an explicit data effective address (zero-extension in Bare),
//	so a tagged pointer accesses the untagged datum. Covers PMLEN7/16 in S/U,
//	MPRV's effective privilege, MXR suppression even in Bare, and full-width
//	fault tval values where bit47/56 distinguishes zero from sign extension.
//	Runs on the htif_tb harness AND spike (same ELF, spike golden).
//	exit 0 = pass; non-zero codes localise the first failing step.

	.equ	TOHOST,		0x80001000
	.equ	BUF,		0x80001100	//	sentinel data slot (bit47=0 -> masks to itself)
	.equ	BUF2,		0x80001108
	.equ	SENT,		0x0000cafe
	.equ	MENVCFG,	0x30a
	.equ	SENVCFG,	0x10a

	// Expected load/store access fault. Check the transformed address, exact
	// fault PC, and that a faulting load did not overwrite its destination.
	.macro	fault_probe op, raw, transformed, cause
	li	s6, \transformed
	li	s7, \cause
	la	s8, .Lfault\@
	li	s10, 0
	li	t1, \raw
	li	t2, 0x11223344
.Lfault\@:
	\op	t2, 0(t1)
	li	t3, 1
	bne	s10, t3, fail_fault
	li	t3, 0x11223344
	bne	t2, t3, fail_canary
	.endm
	.macro	load_sentinel raw, fail_label
	li	t1, \raw
	ld	t2, 0(t1)
	li	t3, SENT
	bne	t2, t3, \fail_label
	.endm

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_trap
	csrw	mtvec, t0			//	any unexpected trap -> FAIL exit
	li	s7, 0
	li	t0, -1
	csrw	pmpaddr0, t0
	li	t0, 0x1f
	csrw	pmpcfg0, t0			//	permit S/U memory in the reference

	//	==== WARL of menvcfg.PMM / senvcfg.PMM ([33:32]: 00/10/11 ok, 01->00) ====
	li	t1, (3 << 32)			//	PMM = 11 (PMLEN16)
	csrw	MENVCFG, t1
	csrr	t2, MENVCFG
	srli	t2, t2, 32
	andi	t2, t2, 3
	li	t3, 3
	bne	t2, t3, fail_warl		//	exit 1
	li	t1, (1 << 32)			//	PMM = 01 reserved -> must read back 00
	csrw	MENVCFG, t1
	csrr	t2, MENVCFG
	srli	t2, t2, 32
	andi	t2, t2, 3
	bne	t2, x0, fail_warl
	//	leave menvcfg.PMM = 11 (S-mode PMLEN16); senvcfg.PMM = 11 (U-mode)
	li	t1, (3 << 32)
	csrw	MENVCFG, t1
	csrw	SENVCFG, t1

	//	sentinel into BUF (M-mode, unmasked)
	li	t0, BUF
	li	t1, SENT
	sd	t1, 0(t0)

	// MPRV selects PMM for the effective privilege, not the executing M mode.
	li	t1, (2 << 32)
	csrw	MENVCFG, t1			//	S: PMLEN7, U still PMLEN16
	li	t0, (1 << 17) | (1 << 11)
	csrw	mstatus, t0
	load_sentinel 0xA800000080001100, fail_mprv
	li	t1, 0xA800000080001108
	li	t2, 0x5566
	sd	t2, 0(t1)
	li	t0, BUF2
	ld	t3, 0(t0)
	bne	t2, t3, fail_mprv
	li	t0, (1 << 17)
	csrw	mstatus, t0
	load_sentinel 0xABCD000080001100, fail_mprv
	li	t1, 0xABCD000080001108
	li	t2, 0x6677
	sd	t2, 0(t1)
	li	t0, BUF2
	ld	t3, 0(t0)
	bne	t2, t3, fail_mprv
	li	t0, (1 << 17) | (3 << 11)
	csrw	mstatus, t0
	fault_probe ld, 0xABCD000080001100, 0xABCD000080001100, 5
	li	t0, (1 << 17) | (3 << 11)
	csrw	mstatus, t0
	fault_probe sd, 0xABCD000080001100, 0xABCD000080001100, 7
	li	t0, (1 << 17) | (1 << 11)
	csrw	mstatus, t0
	fault_probe ld, 0xA900000080001100, 0x0100000080001100, 5
	li	t0, (1 << 17) | (1 << 11)
	csrw	mstatus, t0
	fault_probe sd, 0xA900000080001100, 0x0100000080001100, 7
	li	t0, (1 << 17)
	csrw	mstatus, t0
	fault_probe ld, 0xABCD800080001100, 0x0000800080001100, 5
	li	t0, (1 << 17)
	csrw	mstatus, t0
	fault_probe sd, 0xABCD800080001100, 0x0000800080001100, 7
	li	t0, (1 << 19) | (1 << 17) | (1 << 11)
	csrw	mstatus, t0
	fault_probe ld, 0xA800000080001100, 0xA800000080001100, 5
	li	t0, (1 << 19) | (1 << 17) | (1 << 11)
	csrw	mstatus, t0
	fault_probe sd, 0xA800000080001100, 0xA800000080001100, 7
	li	t0, (1 << 19) | (1 << 17)
	csrw	mstatus, t0
	fault_probe ld, 0xABCD000080001100, 0xABCD000080001100, 5
	li	t0, (1 << 19) | (1 << 17)
	csrw	mstatus, t0
	fault_probe sd, 0xABCD000080001100, 0xABCD000080001100, 7
	csrw	mstatus, zero
	li	t1, (3 << 32)
	csrw	MENVCFG, t1			//	S/U PMLEN16 for the native-mode tests

	//	==== enter S-mode ====
	la	t0, s_main
	csrw	mepc, t0
	csrr	t0, mstatus
	li	t1, (3 << 11)
	not	t1, t1
	and	t0, t0, t1			//	clear MPP
	li	t1, (1 << 11)			//	MPP = S
	or	t0, t0, t1
	csrw	mstatus, t0
	mret

s_main:
	//	Smnpm: menvcfg.PMM=11 -> PMLEN16 in S-mode. A pointer tagged in [63:48]
	//	must access BUF.
	li	t0, BUF
	li	t1, 0xABCD
	slli	t1, t1, 48
	or	t1, t1, t0			//	tagged pointer
	ld	t2, 0(t1)			//	-> masks to BUF -> SENT
	li	t3, SENT
	bne	t2, t3, fail_smnpm		//	exit 2

	//	tagged STORE: write through a tagged pointer, read back untagged
	li	t0, BUF2
	li	t1, 0x1234beef
	li	t4, 0x5555
	slli	t4, t4, 48
	or	t5, t4, t0			//	tagged BUF2 pointer
	sd	t1, 0(t5)			//	masks to BUF2
	ld	t2, 0(t0)			//	untagged read of BUF2
	bne	t2, t1, fail_smnpm

	// Bare PM zero-extends; these transformed physical addresses are holes.
	fault_probe ld, 0xABCD800080001100, 0x0000800080001100, 5
	fault_probe sd, 0xABCD800080001100, 0x0000800080001100, 7
	li	t0, (1 << 19)
	csrs	sstatus, t0
	fault_probe ld, 0xABCD000080001100, 0xABCD000080001100, 5
	fault_probe sd, 0xABCD000080001100, 0xABCD000080001100, 7
	li	t0, (1 << 19)
	csrc	sstatus, t0
	load_sentinel 0xABCD000080001100, fail_smnpm
	li	a6, 1
	ecall					//	M changes S PMM to PMLEN7
	load_sentinel 0xA800000080001100, fail_smnpm
	fault_probe ld, 0xA900000080001100, 0x0100000080001100, 5
	fault_probe sd, 0xA900000080001100, 0x0100000080001100, 7

	//	==== drop to U-mode (SPP=0) ====
	la	t0, u_main
	csrw	sepc, t0
	csrr	t0, sstatus
	li	t1, (1 << 8)
	not	t1, t1
	and	t0, t0, t1			//	SPP = 0 -> U
	csrw	sstatus, t0
	sret

u_main:
	//	Ssnpm: senvcfg.PMM=11 -> PMLEN16 in U-mode. Tagged pointer accesses BUF.
	li	t0, BUF
	li	t1, 0x7777
	slli	t1, t1, 48
	or	t1, t1, t0
	ld	t2, 0(t1)			//	-> SENT
	li	t3, SENT
	bne	t2, t3, fail_ssnpm		//	exit 3 (trap-caught) / direct below
	fault_probe ld, 0xABCD800080001100, 0x0000800080001100, 5
	fault_probe sd, 0xABCD800080001100, 0x0000800080001100, 7
	li	a6, 2
	ecall					//	M sets MXR without changing U PMM
	fault_probe ld, 0xABCD000080001100, 0xABCD000080001100, 5
	fault_probe sd, 0xABCD000080001100, 0xABCD000080001100, 7
	li	a6, 3
	ecall					//	M clears MXR and selects U PMLEN7
	load_sentinel 0xA800000080001100, fail_ssnpm
	fault_probe ld, 0xA900000080001100, 0x0100000080001100, 5
	fault_probe sd, 0xA900000080001100, 0x0100000080001100, 7
	load_sentinel BUF, fail_canary		//	faulting stores did not touch the low alias
	li	t0, BUF2
	ld	t2, 0(t0)
	li	t3, 0x1234beef
	bne	t2, t3, fail_canary

	//	all pass -> exit 0 (store to TOHOST works from U bare)
	li	t0, TOHOST
	li	t1, 1				//	(0<<1)|1
	sd	t1, 0(t0)
1:	j	1b

fail_warl:
	li	t0, (1 << 1) | 1
	j	write_tohost
fail_smnpm:
	li	t0, (2 << 1) | 1
	j	write_tohost
fail_ssnpm:
	//	U-mode: route through ecall-less direct store (still bare)
	li	t0, (3 << 1) | 1
	j	write_tohost
fail_fault:
	li	t0, (4 << 1) | 1
	j	write_tohost
fail_tval:
	li	t0, (5 << 1) | 1
	j	write_tohost
fail_canary:
	li	t0, (6 << 1) | 1
	j	write_tohost
fail_mprv:
	li	t0, (7 << 1) | 1
write_tohost:
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	//	any trap (unexpected fault: a tagged access that was NOT masked, etc.)
	.align 2
m_trap:
	csrr	t4, mcause
	li	t5, 9
	beq	t4, t5, m_service
	li	t5, 8
	beq	t4, t5, m_service
	bne	t4, s7, m_unexpected
	csrr	t4, mepc
	bne	t4, s8, m_unexpected
	csrr	t5, mtval
	bne	t5, s6, fail_tval
	li	s10, 1
	j	m_resume
m_service:
	li	t5, 1
	beq	a6, t5, m_set_s7
	li	t5, 2
	beq	a6, t5, m_set_mxr
	li	t5, 3
	bne	a6, t5, m_unexpected
	li	t5, (1 << 19)
	csrc	mstatus, t5
	li	t5, (2 << 32)
	csrw	SENVCFG, t5
	j	m_service_done
m_set_s7:
	li	t5, (2 << 32)
	csrw	MENVCFG, t5
	j	m_service_done
m_set_mxr:
	li	t5, (1 << 19)
	csrs	mstatus, t5
m_service_done:
	csrr	t4, mepc
m_resume:
	addi	t4, t4, 4
	csrw	mepc, t4
	mret
m_unexpected:
	li	t0, (9 << 1) | 1		//	exit 9 = unexpected trap
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	//	HTIF tohost/fromhost (pinned at 0x80001000 by the linker) so spike's
	//	fesvr detects the exit; the htif_tb harness polls the same address.
	.section .htif,"aw",@progbits
	.globl	tohost
	.align	3
tohost:		.dword 0
	.globl	fromhost
fromhost:	.dword 0
