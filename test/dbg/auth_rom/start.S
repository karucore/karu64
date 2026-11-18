// SPDX-License-Identifier: BSD-2-Clause
//
// Entry of the authentication island ROM. After the window the ROM leaves
// itself: the first instruction issued outside the island closes the window
// in hardware, whatever the window routine did.
//
// AUTH_ROM_NEXT is where control goes. The simulation bench continues in
// its RAM at 0x80000000 and gets a trap vector there. The FPGA build
// (-DAUTH_ROM_NEXT=0x1000 -DAUTH_ROM_NO_MTVEC) hands over to the boot ROM,
// which sets its own trap vector.
#ifndef AUTH_ROM_NEXT
#define AUTH_ROM_NEXT 0x80000000
#endif
    .section .text.start
    .globl _start
_start:
    la      sp, __stack_top
    call    auth_window
#ifndef AUTH_ROM_NO_MTVEC
    li      t0, 0x80000100      // application trap handler (bench RAM)
    csrw    mtvec, t0
#endif
    li      t0, AUTH_ROM_NEXT   // leave the ROM: issue outside it closes the window
    jr      t0
