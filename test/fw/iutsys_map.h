//  iutsys_map.h
//  2025-05-08  Markku-Juhani O. Saarinen <mjos@iki.fi>
//  === memory map

#ifndef _IUTSYS_MAP_H_
#define _IUTSYS_MAP_H_

#ifndef IUTSYS_CLK
#define IUTSYS_CLK          100000000
#endif

//  check that synchronized with: test_top.sv

//  128 kB main ram at 0
#define RAM_ADDR            0x00000000
#define MAIN_RAM            0x20000

//  uart
#define UART_TX_ADDR        0x10000000
#define UART_TXOK_ADDR      0x10000004
#define UART_RX_ADDR        0x10000008
#define UART_RXOK_ADDR      0x1000000C

//  cycle counter
#define GET_TICKS_ADDR      0x10000010

//  gpio
#define GPIO_IN_ADDR        0x10000014
#define GPIO_OUT_ADDR       0x10000018

//  _IUTSYS_MAP_H_
#endif

