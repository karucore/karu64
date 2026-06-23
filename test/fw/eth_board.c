//  eth_board.c
//  Bare-metal LiteEth MAC TX->RX loopback test for the VCU118 DDR board.
//  Identical MAC sequence to test/fw/eth_loopback.c (the proven E1 datapath check),
//  but with NO sim-only SIM_EXIT write -- on the DDR SoC 0x2000 is read-only boot
//  ROM, and there is no bench $finish watcher. It prints the result over the
//  NS16550 console (test/fw/ns16550.c, @0x1000_0000) and parks the core.
//
//  Usage: load to DDR and run from the fu-boot monitor:
//      make eth-board-bin
//      make load_vcu118_ddr KARU_LOAD_BIN=_build/eth_board.bin KARU_LOAD_ADDR=0x80000000
//      (monitor) go 0x80000000
//
//  NOTE: the MAC in vcu118_ddr.bit is in INTERNAL MII loopback (eth_mii_loopback);
//  this validates the karu_eth bridge + liteeth_core datapath in the fabric. It is
//  NOT a test of the external DP83867 PHY (that needs the E3 SGMII front-end).

#include <stdint.h>
#include "karu_hal.h"

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

//  hex only: -march=rv64ic firmware has no hardware divide.
static void put_hex(uint32_t v, int nibbles) {
    sio_puts("0x");
    for (int i = (nibbles - 1) * 4; i >= 0; i -= 4)
        sio_putc("0123456789abcdef"[(v >> i) & 0xf]);
}

static void park(uint32_t code) {
    sio_puts("[ETH-HW] exit code=");
    put_hex(code, 2);
    sio_puts(" (parked)\r\n");
    for (;;) { __asm__ volatile ("wfi"); }
}

#define FRAME_LEN 64

int main(void)
{
    sio_init();
    sio_puts("\r\n[ETH-HW] LiteEth MAC loopback test (internal MII; not the PHY)\r\n");

    //  Confirm the CSR bank is mapped (LiteX ctrl_scratch default = 0x12345678).
    uint32_t scratch = *(volatile uint32_t *)0x11000004UL;
    sio_puts("[ETH-HW] ctrl_scratch=");
    put_hex(scratch, 8);
    sio_putc('\n');

    //  Build a test frame in the TX slot (byte writes exercise full_memory_we).
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
    sio_puts("[ETH-HW] reader_ready=");
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
            sio_puts("[ETH-HW] FAIL: timeout waiting for RX (no loopback)\r\n");
            park(2);
        }
    }

    uint32_t rxslot = mac_rd(WRITER_SLOT);
    uint32_t rxlen  = mac_rd(WRITER_LENGTH);        //  high-word CSR (@0x04)
    sio_puts("[ETH-HW] RX: slot=");
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

    //  Clear the RX event and confirm the pending bit actually clears.
    mac_wr(WRITER_EV_PENDING, 0xffffffff);
    uint32_t still = mac_rd(WRITER_EV_PENDING) & 1;

    int ok = (rxlen == FRAME_LEN) && (mism == 0) && (still == 0);
    if (ok) {
        sio_puts("[ETH-HW] PASS: frame round-tripped, ev cleared\r\n");
    } else {
        sio_puts("[ETH-HW] FAIL:");
        if (rxlen != FRAME_LEN) { sio_puts(" len!=" ); put_hex(FRAME_LEN, 2); }
        if (mism) {
            sio_puts(" mismatch@"); put_hex((uint32_t)first, 2);
            sio_puts("(tx="); put_hex(tx[first < 0 ? 0 : first], 2);
            sio_puts(" rx="); put_hex(rx[first < 0 ? 0 : first], 2); sio_putc(')');
        }
        if (still) sio_puts(" ev_pending_STUCK");
        sio_putc('\n');
    }
    park(ok ? 0 : 1);
    return 0;   //  unreachable
}
