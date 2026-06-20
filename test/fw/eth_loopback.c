//  eth_loopback.c
//  Bare-metal M-mode LiteEth MAC loopback smoke test (karu64, doc/fpga.md
//  E1 / make eth-sim). Runs directly on the linux_tb harness (loaded as +img at
//  0x8000_0000, no OpenSBI/Linux), so it validates the eth datapath -- the
//  karu_eth wishbone bridge + liteeth_core + the sim MII TX->RX loopback -- in
//  seconds instead of a ~25-minute Linux boot. Console is the NS16550 @0x1000_0000
//  (test/fw/ns16550.c), same as the spike/fpga console firmware.
//
//  It drives one frame out the MAC reader (TX), waits for the loopback to deliver
//  it back through the writer (RX), checks the bytes round-tripped, and confirms
//  the RX event pending bit clears (the bit whose stuck-set caused the Linux
//  IRQ storm). Exercises both high-word CSRs (READER_READY@0x1c, WRITER_LENGTH@
//  0x04) and byte-granular slot-SRAM writes.

#include <stdint.h>
#include "iutsys_hal.h"

//  ---- LiteEth MAC layout (flow/fpga/eth/liteeth_csr.csv) ----
#define ETH_MAC   0x11001000UL
#define ETH_BUF   0x11010000UL
#define SLOT_SIZE 2048UL
#define NRX       2UL
#define RX_BASE   (ETH_BUF)
#define TX_BASE   (ETH_BUF + NRX * SLOT_SIZE)   //  0x1101_1000

#define WRITER_SLOT       0x00
#define WRITER_LENGTH     0x04
#define WRITER_EV_PENDING 0x10
#define WRITER_EV_ENABLE  0x14
#define READER_START      0x18
#define READER_READY      0x1c
#define READER_SLOT       0x24
#define READER_LENGTH     0x28
#define READER_EV_PENDING 0x30
#define READER_EV_ENABLE  0x34

static inline uint32_t mac_rd(uint32_t off) {
    return *(volatile uint32_t *)(ETH_MAC + off);
}
static inline void mac_wr(uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(ETH_MAC + off) = v;
}

//  Signal the linux_tb harness to end the run with `code` (0 = pass). The bench
//  ($finish on a write to SIM_EXIT_ADDR) returns it as the process exit code, so
//  `make eth-sim` is a real pass/fail. Must be reached on every exit path.
#define SIM_EXIT_ADDR 0x00002000UL
static void sim_exit(uint32_t code) {
    *(volatile uint32_t *)SIM_EXIT_ADDR = code;
    for (;;) { }    //  bench $finishes on the write above
}

//  hex only: the -march=rv64ic firmware has no hardware divide and -nostdlib
//  drops the libgcc div helpers, so decimal-by-division is unavailable.
static void put_hex(uint32_t v, int nibbles) {
    sio_puts("0x");
    for (int i = (nibbles - 1) * 4; i >= 0; i -= 4)
        sio_putc("0123456789abcdef"[(v >> i) & 0xf]);
}

#define FRAME_LEN 64

int main(void)
{
    sio_init();
    sio_puts("\n[ETH-SIM] LiteEth MAC loopback smoke test\n");

    //  Build a test frame in the TX slot (byte writes exercise full_memory_we):
    //  broadcast dest, a src MAC, an ethertype, then a counting payload.
    volatile uint8_t *tx = (volatile uint8_t *)TX_BASE;
    for (int i = 0; i < 6; i++) tx[i] = 0xff;           //  dest = broadcast
    tx[6] = 0x02; tx[7] = 0x00; tx[8] = 0x00;
    tx[9] = 0x00; tx[10] = 0x00; tx[11] = 0x01;         //  src MAC
    tx[12] = 0x88; tx[13] = 0xb5;                       //  ethertype (experimental)
    for (int i = 14; i < FRAME_LEN; i++) tx[i] = (uint8_t)(i * 7 + 3);

    //  Clear any stale events.
    mac_wr(WRITER_EV_PENDING, 0xffffffff);
    mac_wr(READER_EV_PENDING, 0xffffffff);

    uint32_t ready = mac_rd(READER_READY);      //  high-word CSR (@0x1c)
    sio_puts("[ETH-SIM] reader_ready=");
    put_hex(ready & 1, 1);
    sio_puts(" writer_ev_pending=");
    put_hex(mac_rd(WRITER_EV_PENDING) & 1, 1);
    sio_putc('\n');

    //  Transmit slot 0, FRAME_LEN bytes.
    mac_wr(READER_SLOT, 0);
    mac_wr(READER_LENGTH, FRAME_LEN);
    mac_wr(READER_START, 1);

    //  Wait for the loopback to deliver the frame back to the writer (RX).
    uint32_t spins = 0;
    while (!(mac_rd(WRITER_EV_PENDING) & 1)) {
        if (++spins > 2000000u) {
            sio_puts("[ETH-SIM] FAIL: timeout waiting for RX (no loopback)\n");
            sim_exit(2);
        }
    }

    uint32_t rxslot = mac_rd(WRITER_SLOT);
    uint32_t rxlen  = mac_rd(WRITER_LENGTH);        //  high-word CSR (@0x04)
    sio_puts("[ETH-SIM] RX: slot=");
    put_hex(rxslot, 2);
    sio_puts(" len=");
    put_hex(rxlen, 4);
    sio_putc('\n');

    //  Compare the received bytes against what we sent.
    volatile uint8_t *rx = (volatile uint8_t *)(RX_BASE + rxslot * SLOT_SIZE);
    int mism = 0, first = -1;
    for (int i = 0; i < FRAME_LEN; i++) {
        if (rx[i] != tx[i]) { mism++; if (first < 0) first = i; }
    }

    //  Clear the RX event and confirm the pending bit actually clears (a stuck
    //  pending here is what storms the PLIC under Linux).
    mac_wr(WRITER_EV_PENDING, 0xffffffff);
    uint32_t still = mac_rd(WRITER_EV_PENDING) & 1;

    int ok = (rxlen == FRAME_LEN) && (mism == 0) && (still == 0);
    if (ok) {
        sio_puts("[ETH-SIM] PASS: frame round-tripped, ev cleared\n");
    } else {
        sio_puts("[ETH-SIM] FAIL:");
        if (rxlen != FRAME_LEN) { sio_puts(" len!=" ); put_hex(FRAME_LEN, 2); }
        if (mism) {
            sio_puts(" mismatch@"); put_hex((uint32_t)first, 2);
            sio_puts("(tx="); put_hex(tx[first < 0 ? 0 : first], 2);
            sio_puts(" rx="); put_hex(rx[first < 0 ? 0 : first], 2); sio_putc(')');
        }
        if (still) sio_puts(" ev_pending_STUCK");
        sio_putc('\n');
    }
    sim_exit(ok ? 0 : 1);
    return 0;   //  unreachable (sim_exit spins until the bench $finishes)
}
