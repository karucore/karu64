//  eth_rxdump.c
//  Bare-metal LiteEth MAC RX test for the SGMII datapath hardware trial. Proves the
//  RECEIVE half of the path (host -> DP83867 -> SGMII -> PCS -> GMII RX -> LiteEth MAC
//  writer -> CPU); TX is already proven by test/fw/eth_txblast.c. Polls the LiteEth "writer"
//  (RX) event + slot registers and dumps each received frame's dst/src/ethertype/length
//  + first payload bytes over the NS16550 console (test/fw/ns16550.c, @0x1000_0000).
//
//  Host stimulus (NO root needed): ping an unused IP on the FPGA's subnet so the host
//  broadcasts ARP "who-has" frames the MAC will receive, e.g.:
//      ping 192.168.42.99
//  (dst=ff:ff:ff:ff:ff:ff, src=host MAC, ethertype=0x0806 ARP). Any inbound frame works.
//
//  Run: make eth-rxdump-bin
//       make load_vcu118_ddr KARU_LOAD_BIN=_build/eth_rxdump.bin KARU_LOAD_ADDR=0x80000000
//       make release_vcu118_ddr ; (fu-boot) go 0x80000000
//       drive RTS (flow/hw_monitor.py) so the CTS-gated console drains, then ping from host.

#include <stdint.h>
#include "karu_hal.h"

//  ---- LiteEth MAC layout (flow/fpga/eth/liteeth_csr.csv) ----
#define ETH_MAC   0x11001000UL
#define ETH_BUF   0x11010000UL
#define SLOT_SIZE 2048UL
#define NRX       2UL
#define RX_BASE   (ETH_BUF)

#define WRITER_SLOT       0x00
#define WRITER_LENGTH     0x04
#define WRITER_EV_PENDING 0x10
#define WRITER_EV_ENABLE  0x14

static inline uint32_t mac_rd(uint32_t off) { return *(volatile uint32_t *)(ETH_MAC + off); }
static inline void     mac_wr(uint32_t off, uint32_t v) { *(volatile uint32_t *)(ETH_MAC + off) = v; }

static void put_hex(uint32_t v, int nibbles) {
    sio_puts("0x");
    for (int i = (nibbles - 1) * 4; i >= 0; i -= 4) sio_putc("0123456789abcdef"[(v >> i) & 0xf]);
}
static void put_b2(uint8_t b) {
    sio_putc("0123456789abcdef"[(b >> 4) & 0xf]);
    sio_putc("0123456789abcdef"[b & 0xf]);
}

int main(void)
{
    sio_init();
    sio_puts("\r\n[ETH-RX] LiteEth MAC RX dumper -- frames from the wire (SGMII RX path)\r\n");
    sio_puts("[ETH-RX] host stimulus (no root): ping 192.168.42.99  (-> ARP broadcasts)\r\n");

    uint32_t scratch = *(volatile uint32_t *)0x11000004UL;  //  LiteX ctrl_scratch = 0x12345678
    sio_puts("[ETH-RX] ctrl_scratch="); put_hex(scratch, 8); sio_putc('\n');

    mac_wr(WRITER_EV_PENDING, 0xffffffff);  //  clear any stale RX events
    sio_puts("[ETH-RX] armed; waiting for frames...\r\n");

    uint32_t n = 0;
    for (;;) {
        while (!(mac_rd(WRITER_EV_PENDING) & 1)) { /* poll the RX-available event */ }

        uint32_t slot = mac_rd(WRITER_SLOT);
        uint32_t len  = mac_rd(WRITER_LENGTH);
        volatile uint8_t *rx = (volatile uint8_t *)(RX_BASE + (slot % NRX) * SLOT_SIZE);
        n++;

        sio_puts("[ETH-RX] #"); put_hex(n, 4);
        sio_puts(" slot="); put_hex(slot, 1);
        sio_puts(" len="); put_hex(len, 4);
        sio_puts(" dst="); for (int i = 0;  i < 6;  i++) put_b2(rx[i]);
        sio_puts(" src="); for (int i = 6;  i < 12; i++) put_b2(rx[i]);
        sio_puts(" etype="); put_b2(rx[12]); put_b2(rx[13]);
        sio_puts(" pl="); for (int i = 14; i < 22 && i < (int)len; i++) put_b2(rx[i]);
        sio_putc('\n');

        mac_wr(WRITER_EV_PENDING, 0xffffffff);  //  ack + release the slot for reuse
    }
    return 0;   //  unreachable
}
