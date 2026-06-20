//  config.vh
//  Markku-Juhani O. Saarinen <mjos@iki.fi>.  See LICENSE.
//  === High-level RTL and Firmware configuration

`ifndef CONFIG_VH
`define CONFIG_VH

`include "karu_ext.vh"                  //  F/D/V/K extension enables

`timescale  1 ns / 1 ps
`default_nettype none

`define     IUTSYS                          //  standalone configuration
`define     IUTSYS_CLK  62500000            //  core clock = CLK_125MHZ / 2 = 62.5 MHz (16 ns).
                                                //  vcu118_top divides the 125 MHz LVDS input by 2
                                                //  (BUFGCE_DIV). UART_BITCLKS + the 1 s heartbeat
                                                //  track this. (8 ns/125 MHz did not close timing
                                                //  for IMAFDC: post-route WNS -2.35 ns.)
`ifndef     RAM_XADR
`define     RAM_XADR    17                  //  RAM (1 << RAM_XADR) bytes
`endif

//  === cpu core options
//`define   CORE_DEBUG
`define     CORE_COMPRESSED                 //  "c" - compressed ISA
//`define   CORE_TRAP_UNALIGNED             //  trap on unaligned load/store

//  === communication pins
`define     CONF_GPIO                       //  General purpose IO
`define     CONF_UART_TX                    //  Serial transmit
`define     CONF_UART_RX                    //  Serial receive
`define     UART_BITCLKS (`IUTSYS_CLK/115200) // clocks per bit

`endif
