//  reboot_test.c
//  === Software reset through the system-control register (0x1000_0800).
//
//  Runs M-mode bare-metal on fpga_ddr_top (verilator `make ddr-reboot-test`).
//  The firmware boots twice. A state word in DRAM, outside the image and its
//  .bss, tells the boots apart; DRAM is not cleared by the reset.
//
//    boot 1  the register block reads as zero and does not alias the UART;
//            five writes that must be ignored do not reset the system (wrong
//            value, 16-bit write, 64-bit write, another register of the
//            block, and the right value from a U-mode access made with
//            mstatus.MPRV); then a privileged 32-bit write of 0x7777 must
//            reset it.
//    boot 2  the reset restarted the program from the reset vector, DRAM
//            contents survived, and the peripherals and CSRs changed in
//            boot 1 are back at their reset values.
//
//  If a write that must be ignored resets the system, the next boot finds the
//  state word still at "ignored writes in progress" and fails. If the real
//  request does not reset it, boot 1 runs on into a failure.
//
//  Console + exit go through test/fw/ns16550.c (sio_* + htif_exit).

#include <stdint.h>
#include "sio_generic.h"

#define SYSCTL_BASE     0x10000800UL
#define SYSCTL_RESET    (*(volatile uint32_t *)(SYSCTL_BASE + 0x0))
#define SYSCTL_MAGIC    0x7777u

#define NS16550_BASE    0x10000000UL
#define UART_SCR        (*(volatile uint8_t *)(NS16550_BASE + 7))
#define PLIC_PRIO1      (*(volatile uint32_t *)0x0c000004UL)

//  Test state in DRAM, well clear of the image, its .bss and the stack.
#define STATE           (*(volatile uint64_t *)0x80040000UL)
#define PATTERN         ((volatile uint64_t *)0x80041000UL)
#define PATTERN_WORDS   32
#define TAG             0x5245424f4f540000UL    //  "REBOOT" << 16
#define ST_IGNORED      (TAG | 1)   //  writes that must be ignored are in progress
#define ST_REQUESTED    (TAG | 2)   //  the real request has been written

#define MSTATUS_MPRV    (1UL << 17)
#define MSTATUS_MPP     (3UL << 11)
#define MIE_MTIE         (1UL << 7)

#define csr_read(csr)       ({ uint64_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v)   __asm__ volatile("csrw " #csr ", %0" :: "r"((uint64_t)(v)))
#define csr_set(csr, v)     __asm__ volatile("csrs " #csr ", %0" :: "r"((uint64_t)(v)))
#define csr_clear(csr, v)   __asm__ volatile("csrc " #csr ", %0" :: "r"((uint64_t)(v)))

extern void trap_entry(void);       //  test/fw/irq_trap.S
void htif_exit(int code);           //  test/fw/ns16550.c

static void put_hex(uint64_t v)
{
    static const char hex[] = "0123456789abcdef";
    int i;
    sio_puts("0x");
    for (i = 60; i >= 0; i -= 4)
        sio_putc(hex[(v >> i) & 15]);
}

static void fail(int code, const char *why, uint64_t aux)
{
    STATE = 0;
    sio_puts("[reboot-test] FAIL: ");
    sio_puts(why);
    sio_puts(" aux=");
    put_hex(aux);
    sio_puts("\n");
    htif_exit(code);
}

//  No trap is expected anywhere in this test.
void c_trap(void)
{
    fail(10, "unexpected trap, mcause", csr_read(mcause));
}

static uint64_t pattern(int i)
{
    return 0x9e3779b97f4a7c15UL * (uint64_t)(i + 1);
}

//  Give a wrongly accepted request time to take effect: the reset arrives a
//  couple of cycles after the write.
static void settle(void)
{
    volatile int i;
    for (i = 0; i < 200; i++)
        ;
}

static void first_boot(void)
{
    int i;

    sio_puts("[reboot-test] boot 1\n");
    if (SYSCTL_RESET != 0)
        fail(1, "system-control register does not read as zero", SYSCTL_RESET);

    //  The block must not alias the UART, whose registers used to repeat
    //  through the whole page.
    UART_SCR = 0x5a;
    *(volatile uint8_t *)(SYSCTL_BASE + 7) = 0xa5;
    if (UART_SCR != 0x5a)
        fail(2, "write to the system-control block reached the UART", UART_SCR);

    //  State that the reset must clear (peripheral, CSR) or keep (DRAM).
    PLIC_PRIO1 = 5;
    csr_write(mie, MIE_MTIE);                   //  mstatus.MIE stays 0: no interrupt is taken
    for (i = 0; i < PATTERN_WORDS; i++)
        PATTERN[i] = pattern(i);

    STATE = ST_IGNORED;
    SYSCTL_RESET = 0x1234;                                      //  wrong value
    settle();
    *(volatile uint16_t *)(SYSCTL_BASE + 0) = SYSCTL_MAGIC;     //  16-bit write
    settle();
    *(volatile uint64_t *)(SYSCTL_BASE + 0) = SYSCTL_MAGIC;     //  64-bit write
    settle();
    *(volatile uint32_t *)(SYSCTL_BASE + 8) = SYSCTL_MAGIC;     //  another register
    settle();
    //  The right value from a user-mode access: MPRV with MPP=U makes this
    //  store, and only data accesses, use U-mode privilege.
    csr_clear(mstatus, MSTATUS_MPP);
    csr_set(mstatus, MSTATUS_MPRV);
    SYSCTL_RESET = SYSCTL_MAGIC;
    csr_clear(mstatus, MSTATUS_MPRV);
    settle();

    sio_puts("[reboot-test] ignored writes did not reset; requesting reset\n");
    STATE = ST_REQUESTED;
    SYSCTL_RESET = SYSCTL_MAGIC;
    settle();
    settle();
    fail(3, "privileged write of the reset value did not reset the system", 0);
}

static void second_boot(void)
{
    int i;

    sio_puts("[reboot-test] boot 2\n");
    for (i = 0; i < PATTERN_WORDS; i++)
        if (PATTERN[i] != pattern(i))
            fail(5, "DRAM contents changed across the reset, word", (uint64_t)i);
    if (UART_SCR != 0x00)
        fail(6, "UART was not reset", UART_SCR);
    if (PLIC_PRIO1 != 0)
        fail(7, "PLIC was not reset", PLIC_PRIO1);
    if (csr_read(mie) != 0)
        fail(8, "mie was not reset", csr_read(mie));
    STATE = 0;
    sio_puts("[reboot-test] PASS\n");
    htif_exit(0);
}

int main(void)
{
    uint64_t state = STATE;

    csr_write(mtvec, (uint64_t)&trap_entry);
    if (state == ST_REQUESTED)
        second_boot();
    else if (state == ST_IGNORED)
        fail(4, "a write that must be ignored reset the system", state);
    else
        first_boot();
    return 0;
}
