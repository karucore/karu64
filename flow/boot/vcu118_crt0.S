# vcu118_crt0.S -- freestanding ROM startup.

	.section .text.init, "ax"
	.globl _start
_start:
	la	sp, _stack_top

	la	t0, __data_load_start
	la	t1, _data_start
	la	t2, _data_end
1:	bgeu	t1, t2, 2f
	lw	t3, 0(t0)
	sw	t3, 0(t1)
	addi	t0, t0, 4
	addi	t1, t1, 4
	j	1b

2:	la	t0, _bss_start
	la	t1, _bss_end
3:	bgeu	t0, t1, 4f
	sw	zero, 0(t0)
	addi	t0, t0, 4
	j	3b

4:	call	main
5:	wfi
	j	5b
