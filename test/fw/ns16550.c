//  ns16550.c
//  === NS16550 UART console + HTIF exit.
//
//  One firmware binary drives the console on both spike and the VCU118
//  FPGA target. Spike's builtin 16550 (riscv/ns16550.cc) sits at
//  0x10000000 with reg-shift=0 / reg-io-width=1 (riscv/platform.h), and
//  karu_ns16550.v on the FPGA maps the same byte-register block to the
//  same address, so this driver is identical for both.
//
//  IMPORTANT: spike's model only accepts *byte* accesses (it rejects any
//  load/store whose width != reg_io_width==1). All register touches here
//  go through `volatile uint8_t *`, never word loads.

#include <stdint.h>
#include "sio_generic.h"

#define NS16550_BASE    0x10000000u
#define REG     ((volatile uint8_t *)NS16550_BASE)

//  register offsets (DLAB=0)
#define UART_RBR    0   //  r: receive buffer
#define UART_THR    0   //  w: transmit holding
#define UART_IER    1   //  w: interrupt enable (DLAB=1: divisor hi)
#define UART_DLL    0   //  w: divisor lo       (DLAB=1)
#define UART_DLM    1   //  w: divisor hi       (DLAB=1)
#define UART_IIR    2   //  r: interrupt id
#define UART_FCR    2   //  w: fifo control
#define UART_LCR    3   //  w: line control
#define UART_MCR    4   //  w: modem control
#define UART_LSR    5   //  r: line status
#define UART_MSR    6   //  r: modem status
#define UART_SCR    7   //  r/w: scratch

//  LSR bits
#define UART_LSR_DR 0x01    //  receive data ready
#define UART_LSR_THRE   0x20    //  transmit-hold-register empty
#define UART_LSR_TEMT   0x40    //  transmitter empty

//  LCR bits
#define UART_LCR_DLAB   0x80    //  divisor latch access
#define UART_LCR_8N1    0x03    //  8 data bits, no parity, 1 stop

int sio_init(void)
{
    //  8-N-1, polled (no interrupts). The FPGA baud divisor is fixed at
    //  synth time (karu_ns16550 BITCLKS), and spike ignores the divisor,
    //  so we never program DLL/DLM -- just the frame format.
    REG[UART_LCR] = UART_LCR_8N1;
    REG[UART_IER] = 0x00;
    REG[UART_FCR] = 0x01;   //  enable FIFO (spike); harmless on hw
    return 0;
}

void sio_close(void) { }

void sio_putc(int ch)
{
    while (!(REG[UART_LSR] & UART_LSR_THRE)) { }
    REG[UART_THR] = (uint8_t)ch;
}

void sio_puts(const char *s)
{
    while (*s)
        sio_putc(*s++);
}

//  non-blocking read of one byte; -1 if none available
int sio_getc(void)
{
    if (REG[UART_LSR] & UART_LSR_DR) {
        int ch = REG[UART_RBR];     //  data byte (lane 0). On spike, reading
                                    //  RBR also pops the RX FIFO.
        //  Advance the karu_ns16550 RX. karu64's LSU issues only 8-byte
        //  ALIGNED reads (it extracts the byte itself), so the read channel
        //  cannot tell the device which 16550 register was addressed -- a
        //  read can't be the pop trigger. A write carries its byte lane in
        //  wstrb, so we pop by writing SCR. This is a no-op scratch write on
        //  spike (which already popped on the RBR read above), so the same
        //  binary advances exactly once on both targets.
        REG[UART_SCR] = 0;
        return ch;
    }
    return -1;
}

//  === exit ===
//  Spike terminates on an HTIF tohost write; on the FPGA there is no host
//  consuming tohost, so htif_exit just parks the core in a wfi loop.

volatile uint64_t tohost   __attribute__((section(".tohost"), aligned(8))) = 0;
volatile uint64_t fromhost __attribute__((section(".tohost"), aligned(8))) = 0;

void htif_exit(int code)
{
    while (tohost != 0) { }
    tohost = ((uint64_t)code << 1) | 1;
    for (;;) {
        asm volatile("wfi");
    }
}
