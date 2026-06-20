//	karu_supm_test.S
//	Directed test for Supm (pointer masking): Smnpm (menvcfg.PMM -> S-mode) and
//	Ssnpm (senvcfg.PMM -> U-mode). Bare translation; the masking strips the top
//	PMLEN bits of an explicit data effective address (replacing them with a
//	canonical sign-extension), so a tagged pointer accesses the untagged datum.
//	Runs on the htif_tb harness AND spike (same ELF, spike golden).
//	exit 0 = pass; non-zero codes localise the first failing step.

	.equ	TOHOST,		0x80001000
	.equ	BUF,		0x80001100	//	sentinel data slot (bit47=0 -> masks to itself)
	.equ	BUF2,		0x80001108
	.equ	SENT,		0x0000cafe
	.equ	MENVCFG,	0x30a
	.equ	SENVCFG,	0x10a

	.section .text.boot,"ax"
	.globl	_start
	.option norvc
_start:
	la	t0, m_trap
	csrw	mtvec, t0			//	any unexpected trap -> FAIL exit

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
write_tohost:
	li	t1, TOHOST
	sd	t0, 0(t1)
1:	j	1b

	//	any trap (unexpected fault: a tagged access that was NOT masked, etc.)
	.align 2
m_trap:
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
