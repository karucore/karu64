//  timedom_test.c
//  Regression for the CSR-time / CLINT-mtime domain match -- the bug that wedged the
//  Linux boot (timer interrupt never fired). Per the RISC-V spec, rdtime (CSR `time`,
//  0xC01) MUST be the SAME counter as the CLINT mtime (0x0200_0000 + 0xBFF8): Linux
//  programs SBI timer deadlines as rdtime()+delta, and OpenSBI writes that to mtimecmp,
//  which the CLINT compares against mtime. If rdtime and mtime live in different domains
//  (e.g. raw cyc @75 MHz vs a TICK_DIV'd 1 MHz mtime) the deadline is ~75x too far out and
//  the timer never fires. With the EXT_TIME=1 fix the core's CSR time reads the CLINT
//  mtime, so the two are one counter.
//
//  This test reads both via two methods (csrr time + MMIO mtime), and asserts they are in
//  the SAME domain: near-equal instantaneous values, and equal advance over a delay.
//  PASS on the fixed RTL; FAIL on the old (raw-cyc) CSR time. Console = NS16550.
//  Run: load to DDR + `go 0x80000000` (the interrupt test / DDR board image rig).

#include <stdint.h>
#include "iutsys_hal.h"

#define CLINT_MTIME 0x0200BFF8UL
static inline uint64_t rd_time(void)  { uint64_t t; __asm__ volatile ("csrr %0, time" : "=r"(t)); return t; }
static inline uint64_t rd_mtime(void) { return *(volatile uint64_t *)CLINT_MTIME; }
static inline uint64_t absdiff(uint64_t a, uint64_t b) { return a > b ? a - b : b - a; }

static void put_hex(uint64_t v, int nyb) {
    sio_puts("0x");
    for (int i = (nyb - 1) * 4; i >= 0; i -= 4) sio_putc("0123456789abcdef"[(v >> i) & 0xf]);
}

//  rdtime and the MMIO mtime are read a few (bus-latency) cycles apart, so allow a small
//  skew; the domains differ by ~75x when broken, far above this threshold.
#define SKEW 4096ULL

int main(void)
{
    sio_init();
    sio_puts("\r\n[TIMEDOM] rdtime (CSR 0xC01) vs CLINT mtime (0x0200BFF8) domain check\r\n");

    uint64_t t0 = rd_time(),  m0 = rd_mtime();
    for (volatile uint32_t d = 0; d < 3000000u; d++) { }
    uint64_t t1 = rd_time(),  m1 = rd_mtime();

    uint64_t dt = t1 - t0, dm = m1 - m0;
    sio_puts("[TIMEDOM] t0="); put_hex(t0, 16); sio_puts(" m0="); put_hex(m0, 16); sio_putc('\n');
    sio_puts("[TIMEDOM] t1="); put_hex(t1, 16); sio_puts(" m1="); put_hex(m1, 16); sio_putc('\n');
    sio_puts("[TIMEDOM] dt="); put_hex(dt, 16); sio_puts(" dm="); put_hex(dm, 16); sio_putc('\n');

    int advanced = (dt > 0) && (dm > 0);
    int same_inst = (absdiff(t0, m0) < SKEW) && (absdiff(t1, m1) < SKEW);
    int same_rate = (absdiff(dt, dm) < SKEW);
    int ok = advanced && same_inst && same_rate;

    if (ok) {
        sio_puts("[TIMEDOM] PASS: rdtime and CLINT mtime share one counter domain\r\n");
    } else {
        sio_puts("[TIMEDOM] FAIL:");
        if (!advanced)  sio_puts(" counter(s) not advancing");
        if (!same_inst) sio_puts(" rdtime != mtime (different domains)");
        if (!same_rate) sio_puts(" dt != dm (different rates)");
        sio_putc('\n');
    }
    for (;;) { __asm__ volatile ("wfi"); }
    return 0;
}
