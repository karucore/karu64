//  irq_test.c
//  === Directed interrupt test for the Phase-4 VCU118 SoC (CLINT + PLIC).
//
//  Runs M-mode bare-metal on fpga_top (verilator `make irq-test`):
//    TEST 1  CLINT machine-timer interrupt (mtimecmp/mtime -> MTIP, cause 7)
//    TEST 2  PLIC external interrupt from the NS16550 RX line
//            (UART IRQ -> PLIC source 1 -> MEIP, cause 11; claim/complete)
//
//  Console + exit go through test/fw/ns16550.c (sio_* + htif_exit). On success the
//  firmware calls htif_exit(0); fpga_tb watches the HTIF tohost word and stops
//  with exit 0. Any unexpected trap or a watchdog timeout exits non-zero.

#include <stdint.h>
#include "sio_generic.h"

//  ------------------------------------------------------------------ MMIO map
#define CLINT_BASE      0x02000000UL
#define CLINT_MTIMECMP  (*(volatile uint64_t *)(CLINT_BASE + 0x4000))
#define CLINT_MTIME     (*(volatile uint64_t *)(CLINT_BASE + 0xBFF8))

#define PLIC_BASE       0x0c000000UL
#define PLIC_PRIO1      (*(volatile uint32_t *)(PLIC_BASE + 0x000004))
#define PLIC_ENABLE_M   (*(volatile uint32_t *)(PLIC_BASE + 0x002000))
#define PLIC_THRESH_M   (*(volatile uint32_t *)(PLIC_BASE + 0x200000))
#define PLIC_CLAIM_M    (*(volatile uint32_t *)(PLIC_BASE + 0x200004))

#define NS16550_BASE    0x10000000UL
#define UART            ((volatile uint8_t *)NS16550_BASE)
#define UART_RBR        0
#define UART_IER        1
#define UART_SCR        7

//  mie / mstatus bit positions
#define MIE_MTIE        (1UL << 7)
#define MIE_MEIE        (1UL << 11)
#define MSTATUS_MIE     (1UL << 3)

//  ------------------------------------------------------------------ CSR ops
#define read_csr(r)     ({ uint64_t __v; asm volatile("csrr %0, " #r : "=r"(__v)); __v; })
#define write_csr(r, v) ({ asm volatile("csrw " #r ", %0" :: "rK"((uint64_t)(v))); })
#define set_csr(r, v)   ({ asm volatile("csrs " #r ", %0" :: "rK"((uint64_t)(v))); })
#define clear_csr(r, v) ({ asm volatile("csrc " #r ", %0" :: "rK"((uint64_t)(v))); })

extern void trap_entry(void);       //  test/fw/irq_trap.S
void htif_exit(int code);           //  test/fw/ns16550.c

static volatile int     timer_fired = 0;
static volatile int     ext_fired   = 0;
static volatile uint8_t ext_byte    = 0;

static void put_hex(uint64_t v)
{
    static const char hx[] = "0123456789abcdef";
    int i;
    sio_puts("0x");
    for (i = 60; i >= 0; i -= 4)
        sio_putc(hx[(v >> i) & 0xf]);
}

static void fail(int code, const char *why, uint64_t aux)
{
    sio_puts("[irq-test] FAIL: ");
    sio_puts(why);
    sio_puts(" aux=");
    put_hex(aux);
    sio_putc('\n');
    htif_exit(code);
}

//  ------------------------------------------------- trap handler (from shim)
void c_trap(void)
{
    uint64_t cause = read_csr(mcause);

    if (!(cause & (1UL << 63))) {
        //  synchronous exception: never expected in this test.
        fail(0x40, "sync exception", cause);
        return;
    }

    switch (cause & 0xff) {
    case 7:     //  machine timer (MTIP)
        CLINT_MTIMECMP = 0xFFFFFFFFFFFFFFFFUL;  //  push compare out: deassert MTIP
        clear_csr(mie, MIE_MTIE);
        timer_fired = 1;
        break;

    case 11: {  //  machine external (MEIP) via PLIC
        uint32_t id = PLIC_CLAIM_M;             //  claim the active source
        if (id == 1) {
            ext_byte = UART[UART_RBR];          //  read RX byte ...
            UART[UART_SCR] = 0;                 //  ... and pop it (deassert IRQ)
        }
        PLIC_CLAIM_M = id;                      //  complete (ignored by level PLIC)
        clear_csr(mie, MIE_MEIE);
        ext_fired = 1;
        break;
    }

    default:
        fail(0x41, "unexpected irq", cause);
        break;
    }
}

//  ---------------------------------------------------------------- spin guard
#define WATCHDOG 4000000UL

int main(void)
{
    sio_init();
    sio_puts("[irq-test] start\n");

    write_csr(mtvec, (uint64_t)&trap_entry);    //  direct mode (4-byte aligned)
    set_csr(mstatus, MSTATUS_MIE);              //  global M interrupt enable

    //  ================= TEST 1: CLINT machine-timer interrupt ===============
    {
        uint64_t now = CLINT_MTIME;
        CLINT_MTIMECMP = now + 5;               //  fire a few mtime ticks out
        set_csr(mie, MIE_MTIE);

        volatile uint64_t g = 0;
        while (!timer_fired)
            if (++g > WATCHDOG)
                fail(1, "timer never fired, mtime=", CLINT_MTIME);
    }
    sio_puts("[irq-test] timer interrupt OK\n");

    //  ================= TEST 2: PLIC external (UART RX) interrupt ===========
    {
        PLIC_PRIO1     = 1;                     //  source 1 priority > threshold
        PLIC_THRESH_M  = 0;
        PLIC_ENABLE_M  = (1u << 1);             //  enable source 1 for M-context
        set_csr(mie, MIE_MEIE);
        UART[UART_IER] = 0x01;                  //  ERBFI: RX-data-available IRQ

        volatile uint64_t g = 0;
        while (!ext_fired)
            if (++g > WATCHDOG)
                fail(2, "external never fired", 0);

        if (ext_byte != 'K')
            fail(3, "wrong RX byte", ext_byte);
    }
    sio_puts("[irq-test] external interrupt OK (rx='");
    sio_putc(ext_byte);
    sio_puts("')\n");

    //  ========== TEST 3: interrupt taken DURING a long vector op ============
    //  The drain gate (irq_take requires !exec_busy, exec_busy includes
    //  varith_active/vlsu_active) must hold a pending interrupt off until the
    //  vector op retires. We arm the timer to fire ~1 mtime tick out, then run
    //  a long vfsqrt.v over 32 e64 elements (~hundreds of cycles): the deadline
    //  lands while the op is in flight. PASS proves (a) the IRQ was still taken
    //  and (b) every element result is exact (4.0 -> 2.0) -- a mid-op interrupt
    //  would corrupt the result, hang the FU (watchdog TIMEOUT), or trip an
    //  unexpected cause.
    {
        static uint64_t vsrc[32], vdst[32];
        const uint64_t  FOUR = 0x4010000000000000ULL;   //  (double)4.0
        const uint64_t  TWO  = 0x4000000000000000ULL;   //  (double)2.0
        int i;
        for (i = 0; i < 32; i++) { vsrc[i] = FOUR; vdst[i] = 0; }

        timer_fired = 0;
        CLINT_MTIMECMP = CLINT_MTIME + 1;           //  fire within ~1 tick
        set_csr(mie, MIE_MTIE);

        asm volatile(
            "vsetvli  t0, %2, e64, m8, ta, ma \n"
            "vle64.v  v8, (%0)                \n"
            "vfsqrt.v v8, v8                  \n"   //  long: 54-cyc/elem bit-serial
            "vse64.v  v8, (%1)                \n"
            :
            : "r"(vsrc), "r"(vdst), "r"((uint64_t)32)
            : "t0", "memory");

        volatile uint64_t g = 0;
        while (!timer_fired)
            if (++g > WATCHDOG)
                fail(4, "timer-during-vector never fired", CLINT_MTIME);

        for (i = 0; i < 32; i++)
            if (vdst[i] != TWO)
                fail(5, "vector result corrupted at i*16+lo", ((uint64_t)i << 16) | (vdst[i] & 0xffff));
    }
    sio_puts("[irq-test] interrupt-during-vector-op OK\n");

    //  ========= TEST 4: interrupt during a VLSU op's PREFLIGHT =============
    //  A long STRIDED store (vsse64, 32 e64 elements) translates every
    //  element in its preflight BEFORE any memory side effect (V2 precise
    //  preflight), then commits. The timer deadline lands while the op is in
    //  flight. The drain gate (irq_take requires !vlsu_active) must hold the
    //  interrupt off until the op fully retires, so EVERY element is stored
    //  exactly once and the stride GAPS are untouched -- a mid-preflight
    //  interrupt would risk a partial store, a duplicated commit on vstart
    //  restart, or a clobbered gap.
    {
        static uint64_t vssrc[32];
        static uint64_t vsdst[64];          //  stride-2: data at even slots, gaps odd
        int i;
        for (i = 0; i < 32; i++) vssrc[i] = 0xA5A5000000000000ULL | (uint64_t)i;
        for (i = 0; i < 64; i++) vsdst[i] = 0xDEADBEEFDEADBEEFULL;

        //  load the source first (untimed; not in the observer window)
        asm volatile("vsetvli t0, %1, e64, m8, ta, ma \n vle64.v v8, (%0)\n"
            :: "r"(vssrc), "r"((uint64_t)32) : "t0", "memory");

        //  mark the TEST-4 window so the testbench observer only credits THIS
        //  strided store (not TEST 3's incidental VLSU). 0x80001100 = unused
        //  scratch above tohost; karu_mem is write-through so the TB sees it.
        volatile uint64_t *MARK = (volatile uint64_t *)0x80001100UL;
        *MARK = 1;
        timer_fired = 0;
        CLINT_MTIMECMP = CLINT_MTIME + 1;           //  fire within ~1 tick
        set_csr(mie, MIE_MTIE);

        asm volatile(
            "li       t1, 16                  \n"   //  stride = 16 B (every other u64)
            "vsse64.v v8, (%0), t1            \n"   //  strided store: per-element preflight
            :
            : "r"(vsdst)
            : "t1", "memory");

        volatile uint64_t g = 0;
        while (!timer_fired)
            if (++g > WATCHDOG)
                fail(6, "timer-during-vlsu-preflight never fired", CLINT_MTIME);
        *MARK = 0;

        for (i = 0; i < 32; i++) {
            if (vsdst[i*2] != (0xA5A5000000000000ULL | (uint64_t)i))
                fail(7, "strided store element wrong", ((uint64_t)i << 32) | (vsdst[i*2] & 0xffffffff));
            if (vsdst[i*2 + 1] != 0xDEADBEEFDEADBEEFULL)
                fail(8, "strided store clobbered a gap", ((uint64_t)i << 32) | (vsdst[i*2+1] & 0xffffffff));
        }
    }
    sio_puts("[irq-test] interrupt-during-VLSU-preflight OK\n");

    sio_puts("[irq-test] PASS\n");
    htif_exit(0);
    return 0;
}
