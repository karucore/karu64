//  noise_burst_test.c
//  === The burst-capture registers of the entropy source, through the SoC.
//
//  Runs M-mode bare-metal on fpga_ddr_top with KARU_ZKR (verilator
//  `make ddr-noise-burst-test`). The block itself has its own bench
//  (test/tb_noise_burst.sv); this test is about the path to it: the decode
//  of 0x1000_0840..0x1000_087f in the system-control block of
//  flow/fpga/karu_ddr_xbar.v, which passes on privileged 64-bit accesses
//  only, and the test mode of the entropy block as the core's mnoise CSR
//  sets it.
//
//    1  outside test mode: the block identifies itself, holds nothing, and
//       takes no setting; the rest of the system-control block reads zero
//    2  test mode: period, a capture, the data through the index
//    3  accesses that must not be passed on: 32-, 16- and 8-bit reads and
//       writes, and U-mode accesses (made with mstatus.MPRV); a read that is
//       not passed on returns zero and does not move the index
//    4  neighbours: the temperature readout, the meter's three registers
//       (karu_rosc_meter.v: its control register, a record, and the same
//       rules for narrow and U-mode accesses), the reset register and the
//       UART
//    5  leaving test mode: nothing is held, the period is the build's again
//
//  The mutants of the decode (test/fw/noise_burst_mutants.txt) must each
//  fail with their own message.
//
//  Console + exit go through test/fw/ns16550.c (sio_* + htif_exit).

#include <stdint.h>
#include "sio_generic.h"

#define SYSCTL_BASE     0x10000800UL
#define NB_BASE         (SYSCTL_BASE + 0x40)
#define R64(a)          (*(volatile uint64_t *)(a))
#define R32(a)          (*(volatile uint32_t *)(a))
#define R16(a)          (*(volatile uint16_t *)(a))
#define R8(a)           (*(volatile uint8_t *)(a))
#define NB_CTRL         R64(NB_BASE + 0)
#define NB_PERIOD       R64(NB_BASE + 8)
#define NB_INDEX        R64(NB_BASE + 16)
#define NB_DATA         R64(NB_BASE + 24)
#define NB_SYSMON       R64(NB_BASE + 32)   /* temperature and supplies, karu_sysmon.v */
#define MT_BASE         (NB_BASE + 40)      /* the meter, karu_rosc_meter.v */
#define MT_CTRL         R64(MT_BASE + 0)
#define MT_DATA0        R64(MT_BASE + 8)
#define MT_DATA1        R64(MT_BASE + 16)
#define NB_MAGIC        0x4b4e4231UL

#define ST_BUSY         1UL
#define ST_DONE         2UL
#define ST_ALLOW        4UL
#define ST_LOCK         8UL
#define ST_SOURCE       16UL
#define ST_TEST         32UL

#define NS16550_BASE    0x10000000UL
#define UART_SCR        R8(NS16550_BASE + 7)

#define CSR_MNOISE      0x7C8
#define NOISE_TEST      (1UL << 31)

#define MSTATUS_MPRV    (1UL << 17)
#define MSTATUS_MPP     (3UL << 11)

#define csr_read(csr)       ({ uint64_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v)   __asm__ volatile("csrw " #csr ", %0" :: "r"((uint64_t)(v)))
#define csr_set(csr, v)     __asm__ volatile("csrs " #csr ", %0" :: "r"((uint64_t)(v)))
#define csr_clear(csr, v)   __asm__ volatile("csrc " #csr ", %0" :: "r"((uint64_t)(v)))

extern void trap_entry(void);       //  test/fw/irq_trap.S
void htif_exit(int code);           //  test/fw/ns16550.c

#define MAX_WORDS 4096
static uint64_t burst[MAX_WORDS];
static uint64_t words, build_period;

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
    csr_write(0x7C8, 0);
    sio_puts("[noise-burst-test] FAIL: ");
    sio_puts(why);
    sio_puts(" aux=");
    put_hex(aux);
    sio_puts("\n");
    htif_exit(code);
}

//  No trap is expected anywhere in this test.
void c_trap(void)
{
    fail(10, "trap, mcause", csr_read(mcause));
}

static uint64_t flags(void)
{
    return NB_CTRL & 0x3f;
}

static void capture(void)
{
    uint64_t i, guard = 0;

    NB_CTRL = 1;
    while (!(NB_CTRL & ST_DONE))
        if (++guard > 4000000)
            fail(20, "capture did not complete", NB_CTRL);
    NB_INDEX = 0;
    for (i = 0; i < words; i++)
        burst[i] = NB_DATA;
}

//  A data access with U-mode privilege: MPRV with MPP=U applies to loads and
//  stores only.
static uint64_t user_read(uint64_t addr)
{
    uint64_t v;
    csr_clear(mstatus, MSTATUS_MPP);
    csr_set(mstatus, MSTATUS_MPRV);
    v = R64(addr);
    csr_clear(mstatus, MSTATUS_MPRV);
    return v;
}
static void user_write(uint64_t addr, uint64_t v)
{
    csr_clear(mstatus, MSTATUS_MPP);
    csr_set(mstatus, MSTATUS_MPRV);
    R64(addr) = v;
    csr_clear(mstatus, MSTATUS_MPRV);
}

int main(void)
{
    uint64_t v, w, i, nonzero = 0, differ = 0;

    csr_write(mtvec, (uint64_t)&trap_entry);

    //  ---- 1: outside test mode ----
    v = NB_CTRL;
    if ((v >> 32) != NB_MAGIC)
        fail(1, "no capture block", v);
    words = 1UL << (((v >> 8) & 0xff) - 4);
    if (words < 2 || words > MAX_WORDS)
        fail(1, "burst size", words);
    if (flags() != ST_SOURCE)
        fail(2, "status outside test mode", flags());
    build_period = NB_PERIOD;
    if (build_period > 255)
        fail(2, "period range", build_period);
    if (NB_DATA != 0 || NB_INDEX != 0)
        fail(2, "data or index outside test mode", NB_DATA);
    NB_PERIOD = 0;
    NB_CTRL = 1;
    NB_INDEX = 1;
    if (NB_PERIOD != build_period || flags() != ST_SOURCE || NB_INDEX != 0 || NB_DATA != 0)
        fail(3, "write outside test mode had an effect", NB_CTRL);
    if (R64(SYSCTL_BASE) != 0 || R64(SYSCTL_BASE + 8) != 0 || R64(SYSCTL_BASE + 0x38) != 0 || R64(SYSCTL_BASE + 0x80) != 0)
        fail(4, "sysctl reads nonzero", R64(SYSCTL_BASE));

    //  ---- 2: test mode ----
    csr_write(0x7C8, NOISE_TEST);
    if (flags() != (ST_SOURCE | ST_ALLOW | ST_TEST))
        fail(5, "status in test mode", flags());
    NB_PERIOD = 2;
    if (NB_PERIOD != 2)
        fail(5, "period not taken", NB_PERIOD);
    capture();
    for (i = 0; i < words; i++) {
        nonzero |= burst[i];
        if (i && burst[i] != burst[0])
            differ = 1;
    }
    if (!nonzero || !differ)
        fail(6, "burst all zero or all one word", burst[0]);
    if (NB_INDEX != 0)
        fail(6, "index did not wrap", NB_INDEX);
    NB_INDEX = 1;
    if (NB_DATA != burst[1] || NB_DATA != burst[2] || NB_INDEX != 3)
        fail(6, "reread through the index", NB_INDEX);

    //  ---- 3: accesses that must not be passed on ----
    //  narrow reads of the data register: zero, and the index stays
    NB_INDEX = 1;
    if (R32(NB_BASE + 24) != 0 || R16(NB_BASE + 24) != 0 || R8(NB_BASE + 24) != 0 || R32(NB_BASE + 28) != 0)
        fail(30, "narrow read of data returned data", R32(NB_BASE + 24));
    if (NB_INDEX != 1)
        fail(30, "narrow read moved the index", NB_INDEX);
    if (R32(NB_BASE + 0) != 0 || R32(NB_BASE + 4) != 0)
        fail(30, "narrow read of status returned data", R32(NB_BASE + 4));
    //  narrow writes: no effect
    R32(NB_BASE + 8) = 0;
    R16(NB_BASE + 8) = 0;
    R8(NB_BASE + 8) = 0;
    R32(NB_BASE + 16) = 2;
    if (NB_PERIOD != 2 || NB_INDEX != 1)
        fail(31, "narrow write changed a register", NB_PERIOD);
    R32(NB_BASE + 0) = 1;
    if (flags() != (ST_SOURCE | ST_ALLOW | ST_TEST | ST_DONE))
        fail(31, "narrow write started a capture", flags());
    //  U-mode
    NB_INDEX = 1;
    if (user_read(NB_BASE + 24) != 0)
        fail(32, "U-mode read of data returned data", 0);
    if (NB_INDEX != 1)
        fail(32, "U-mode read moved the index", NB_INDEX);
    if (user_read(NB_BASE + 0) != 0)
        fail(32, "U-mode read of status returned data", 0);
    user_write(NB_BASE + 8, 0);
    user_write(NB_BASE + 16, 2);
    if (NB_PERIOD != 2 || NB_INDEX != 1)
        fail(33, "U-mode write changed a register", NB_PERIOD);
    user_write(NB_BASE + 0, 1);
    if (flags() != (ST_SOURCE | ST_ALLOW | ST_TEST | ST_DONE))
        fail(33, "U-mode write started a capture", flags());
    if (NB_DATA != burst[1])
        fail(34, "recording changed", NB_DATA);

    //  ---- 4: the temperature readout, then the neighbours ----
    //  The simulation model: 40.0 deg C, 0.850 V, 1.800 V, an update every
    //  1024 clocks. Any read works, in or out of test mode; nothing writes it.
    v = NB_SYSMON;
    if ((v & 0xffffffffffffUL) != 0x999a4888a0f6UL || (v >> 48) == 0)
        fail(45, "temperature readout", v);
    NB_SYSMON = 0;
    if (user_read(NB_BASE + 32) != 0)
        fail(45, "U-mode read of the readout returned data", 0);
    for (i = 0; i < 20000 && (NB_SYSMON >> 48) == (v >> 48); i++)
        ;
    if ((NB_SYSMON >> 48) == (v >> 48) || (NB_SYSMON & 0xffffffffffffUL) != (v & 0xffffffffffffUL))
        fail(46, "the readout does not update", NB_SYSMON);
    //  The meter has the three registers after the readout. In test mode
    //  its control register shows the rings of normal operation, here the
    //  four lanes, as the strap and as the mask, and a record at every symbol.
    v = MT_CTRL;
    if (((v >> 32) & 0x3f) != 0x0f || ((v >> 16) & 0x3f) != 0x0f || (v & 0xffff) != 0)
        fail(40, "meter control register in test mode", v);
    if (user_read(MT_BASE) != 0 || user_read(MT_BASE + 8) != 0 || user_read(MT_BASE + 16) != 0)
        fail(47, "U-mode read of the meter returned data", 0);
    if (R32(MT_BASE) != 0 || R32(MT_BASE + 8) != 0 || R16(MT_BASE + 16) != 0)
        fail(47, "narrow read of the meter returned data", 0);
    user_write(MT_BASE, 3);
    R32(MT_BASE) = 3;
    if ((MT_CTRL & 0xffff) != 0)
        fail(47, "U-mode or narrow write changed the meter", MT_CTRL);
    //  a record, at every 256th symbol with the mask as it is (far enough
    //  apart for the reads below to fall between two records): held until
    //  a full-width M-mode read of the second word takes it
    MT_CTRL = (1UL << 31) | (0x0fUL << 16) | 255;
    for (i = 0; i < 20000 && !(MT_DATA0 >> 63); i++)
        ;
    v = MT_DATA0;
    if (!(v >> 63) || ((v >> 62) & 1))
        fail(48, "no meter record, or one with loss", v);
    (void)user_read(MT_BASE + 16);
    (void)R32(MT_BASE + 16);
    if (MT_DATA0 != v)
        fail(48, "a U-mode or narrow read took the meter's record", MT_DATA0);
    w = MT_DATA1;
    if (((w >> 20) & 0xffffffffffUL) != 0)
        fail(48, "the reference rings are off, yet their totals moved", w);
    for (i = 0; i < 20000 && (!(MT_DATA0 >> 63) || ((MT_DATA0 >> 60) & 3) == ((v >> 60) & 3)); i++)
        ;
    w = MT_DATA0;
    if (!(w >> 63) || ((w >> 60) & 3) == ((v >> 60) & 3) || (w & 0xfffff) == (v & 0xfffff))
        fail(48, "the meter's next record: not taken before, or lane 0 did not count", w);
    R64(SYSCTL_BASE + 8) = 0;                   //  would be the period register if the block were not decoded
    R64(SYSCTL_BASE + 0x88) = 0;
    R64(SYSCTL_BASE + 0x48 + 0x400) = 0;
    if (NB_PERIOD != 2 || flags() != (ST_SOURCE | ST_ALLOW | ST_TEST | ST_DONE))
        fail(41, "write elsewhere reached the capture registers", NB_PERIOD);
    if (R64(SYSCTL_BASE) != 0 || R64(SYSCTL_BASE + 0x18) != 0 || R64(SYSCTL_BASE + 0x98) != 0 || R64(SYSCTL_BASE + 0x458) != 0)
        fail(42, "capture registers repeat elsewhere", R64(SYSCTL_BASE));
    UART_SCR = 0x5a;
    NB_INDEX = 3;
    if (UART_SCR != 0x5a)
        fail(43, "write reached the UART", UART_SCR);

    //  a second capture at another period replaces the first
    NB_PERIOD = 0;
    capture();
    if (NB_PERIOD != 0)
        fail(44, "period after second capture", NB_PERIOD);

    //  ---- 5: leaving test mode ----
    NB_INDEX = 0;
    if (NB_DATA != burst[0])
        fail(50, "recording not readable", 0);
    csr_write(0x7C8, 0);
    if (csr_read(0x7C8) != 1)
        fail(50, "mnoise after test mode", csr_read(0x7C8));
    if (flags() != ST_SOURCE || NB_PERIOD != build_period || NB_INDEX != 0 || NB_DATA != 0)
        fail(51, "state held after test mode", NB_CTRL);
    if (MT_CTRL != 0 || MT_DATA0 != 0 || MT_DATA1 != 0)
        fail(51, "the meter answers outside test mode", MT_CTRL);
    csr_write(0x7C8, NOISE_TEST);
    if (flags() != (ST_SOURCE | ST_ALLOW | ST_TEST) || NB_DATA != 0 || NB_PERIOD != build_period)
        fail(52, "old recording or period back in test mode", NB_CTRL);
    csr_write(0x7C8, 0);

    sio_puts("[noise-burst-test] PASS\n");
    htif_exit(0);
    return 0;
}
