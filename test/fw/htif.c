//  htif.c
//  === Standard RISC-V HTIF console + exit, used by spike.
//
//  HTIF is a pair of doubleword "mailboxes" (tohost/fromhost) that the
//  simulator polls. Writing to tohost issues either:
//    - an exit:        bit 0 set, code = (tohost >> 1)
//    - a device cmd:   bits[63:56]=device, [55:48]=cmd, [47:0]=payload
//  The console device is device 1, cmd 1 = write a byte.

#include <stdint.h>
#include "sio_generic.h"

volatile uint64_t tohost   __attribute__((section(".tohost"), aligned(8))) = 0;
volatile uint64_t fromhost __attribute__((section(".tohost"), aligned(8))) = 0;

static void htif_send(uint64_t cmd)
{
    while (tohost != 0) { }     //  wait for prev command to be consumed
    tohost = cmd;
}

void sio_putc(int ch)
{
    htif_send(((uint64_t)1 << 56) | ((uint64_t)1 << 48) | (uint8_t)ch);
}

void sio_puts(const char *s)
{
    while (*s) sio_putc(*s++);
}

void htif_exit(int code)
{
    while (tohost != 0) { }
    tohost = ((uint64_t)code << 1) | 1;
    for (;;) { }
}
