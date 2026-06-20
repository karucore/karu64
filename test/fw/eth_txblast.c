//  eth_txblast.c
//  Bare-metal LiteEth TX blaster for the SGMII-datapath hardware trial. Repeatedly
//  transmits a broadcast Ethernet frame out the MAC -> GMII -> 1G PCS/PMA -> DP83867
//  -> the wire, so a host `tcpdump -i <iface>` sees REAL frames crossing the PHY. This
//  is the first on-wire datapath proof (independent of AN/link fully settling -- the
//  host sees frames as soon as the SGMII link is up). The SGMII bitstream has no
//  internal MII loopback, so this is a pure TX path. Console = NS16550 @0x1000_0000.
//
//  Run: make eth-txblast-bin ; load to DDR (make load_vcu118_ddr
//  KARU_LOAD_BIN=_build/eth_txblast.bin KARU_LOAD_ADDR=0x80000000) ; release ; (monitor)
//  go 0x80000000 ; then on the host: sudo tcpdump -i enx00e04c68752e -e -XX ether host
//  02:00:00:00:00:2a (or ether broadcast).

#include <stdint.h>
#include "iutsys_hal.h"

#define ETH_MAC   0x11001000UL
#define ETH_BUF   0x11010000UL
#define SLOT_SIZE 2048UL
#define NRX       2UL
#define TX_BASE   (ETH_BUF + NRX * SLOT_SIZE)   //  0x1101_1000

#define READER_START      0x18
#define READER_READY      0x1c
#define READER_SLOT       0x24
#define READER_LENGTH     0x28
#define READER_EV_PENDING 0x30

static inline uint32_t mac_rd(uint32_t off) { return *(volatile uint32_t *)(ETH_MAC + off); }
static inline void     mac_wr(uint32_t off, uint32_t v) { *(volatile uint32_t *)(ETH_MAC + off) = v; }

static void put_hex(uint32_t v, int n) {
    sio_puts("0x");
    for (int i = (n - 1) * 4; i >= 0; i -= 4) sio_putc("0123456789abcdef"[(v >> i) & 0xf]);
}

#define FRAME_LEN 64

int main(void)
{
    sio_init();
    sio_puts("\r\n[ETH-TX] SGMII TX blaster -- broadcast frames out the DP83867\r\n");
    sio_puts("[ETH-TX] watch the host: tcpdump -i <iface> -e -XX ether broadcast\r\n");

    //  Broadcast frame: dest=ff:ff:ff:ff:ff:ff, src=02:00:00:00:00:2a (.42 host net),
    //  ethertype 0x88b5 (local experimental), payload = a recognizable tag + a counter.
    volatile uint8_t *tx = (volatile uint8_t *)TX_BASE;
    for (int i = 0; i < 6; i++) tx[i] = 0xff;
    tx[6] = 0x02; tx[7] = 0x00; tx[8] = 0x00; tx[9] = 0x00; tx[10] = 0x00; tx[11] = 0x2a;
    tx[12] = 0x88; tx[13] = 0xb5;
    const char *msg = "KARU64-SGMII-HELLO ";
    int j = 14;
    for (const char *p = msg; *p && j < FRAME_LEN; p++) tx[j++] = (uint8_t)*p;
    for (; j < FRAME_LEN; j++) tx[j] = (uint8_t)j;

    mac_wr(READER_EV_PENDING, 0xffffffff);

    uint32_t n = 0;
    for (;;) {
        uint32_t spins = 0;
        while (!(mac_rd(READER_READY) & 1)) { if (++spins > 5000000u) break; }
        //  stamp a counter into the last 4 payload bytes so frames differ on the wire.
        tx[FRAME_LEN-4] = (uint8_t)(n >> 24); tx[FRAME_LEN-3] = (uint8_t)(n >> 16);
        tx[FRAME_LEN-2] = (uint8_t)(n >> 8);  tx[FRAME_LEN-1] = (uint8_t)n;
        mac_wr(READER_SLOT, 0);
        mac_wr(READER_LENGTH, FRAME_LEN);
        mac_wr(READER_START, 1);
        n++;
        if ((n & 0xf) == 0) {
            sio_puts("[ETH-TX] sent="); put_hex(n, 4);
            sio_puts(" reader_ready="); put_hex(mac_rd(READER_READY) & 1, 1);
            sio_putc('\n');
        }
        //  ~a few hundred ms between frames (crude busy-wait at 75 MHz).
        for (volatile uint32_t d = 0; d < 8000000u; d++) { }
    }
    return 0;   //  unreachable
}
