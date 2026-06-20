// rvmodel_macros.h — karu64 DUT-specific macros for the ACT4 framework.
// SPDX-License-Identifier: BSD-3-Clause
//
// karu64 uses the spike/fesvr HTIF protocol over a single `tohost` dword,
// exactly as test/fw/htif.c and rtl/htif_tb.v already implement it:
//   - console putc : tohost = (1<<56)|(1<<48)|ch   (device 1, cmd 1)
//   - exit         : tohost = (code<<1)|1          (code 0 = PASS)
//   - the firmware must wait for the TB to drain (tohost==0) before the
//     next write.
//
// The testbench watcher (htif_tb.v) samples ram[tohost] EVERY cycle and
// acts on any non-zero value, so we must never expose a partially-written
// packet. The reference RVI20U64 macros write `tohost` as two 32-bit
// stores; on karu64's cycle-accurate watcher the intermediate state (low
// half only) can look like a spurious exit/console event. We therefore
// write the full 64-bit value with a single `sd`, and poll tohost==0
// before each write — matching test/fw/htif.c.

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION                                \
        .pushsection .tohost,"aw",@progbits;                \
        .align 8; .global tohost;   tohost:   .dword 0;     \
        .align 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

// ----------------------- Startup -----------------------
// karu64 resets into M-mode at 0x80000000 with a minimal CSR set. Bypass
// the framework's default M-mode boot (as the vetted RVI20U64 config does)
// and run straight from reset.
#define RVMODEL_BOOT
#define RVMODEL_BOOT_TO_MMODE

// ----------------------- Termination -----------------------
// PASS = tohost 1 (code 0); FAIL = tohost 3 (code 1). Drain first so a
// trailing console packet isn't clobbered, then write the exit dword and
// spin (the TB calls $finish on seeing it).

#define RVMODEL_HALT_PASS         \
  la   t0, tohost               ;\
1:                              ;\
  ld   t2, 0(t0)                ;\
  bnez t2, 1b                   ;\
  li   t1, 1                    ;\
  sd   t1, 0(t0)                ;\
2:                              ;\
  j    2b                       ;

#define RVMODEL_HALT_FAIL         \
  la   t0, tohost               ;\
1:                              ;\
  ld   t2, 0(t0)                ;\
  bnez t2, 1b                   ;\
  li   t1, 3                    ;\
  sd   t1, 0(t0)                ;\
2:                              ;\
  j    2b                       ;

// ----------------------- IO (HTIF console) -----------------------

#define RVMODEL_IO_INIT(_R1, _R2, _R3)

// Print a NUL-terminated string via HTIF console putc. _STR_PTR -> string.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)               \
  la   _R2, tohost                   ;\
1:                                   ;\
  lbu  _R1, 0(_STR_PTR)              ;/* next char */                \
  beqz _R1, 3f                       ;/* NUL -> done */              \
2:                                   ;/* wait for TB to drain */     \
  ld   _R3, 0(_R2)                   ;\
  bnez _R3, 2b                       ;\
  li   _R3, 0x01010000               ;/* device 1, cmd 1 ... */      \
  slli _R3, _R3, 32                  ;/* ... into bits [63:32] */    \
  or   _R1, _R1, _R3                 ;/* full console packet */      \
  sd   _R1, 0(_R2)                   ;\
  addi _STR_PTR, _STR_PTR, 1         ;\
  j    1b                            ;\
3:

// ----------------------- Faults / interrupts -----------------------
// karu64 is M-mode only with a single external IRQ line. The priv /
// interrupt / PMP / Sv test groups are excluded at generation time
// (EXCLUDE_EXTENSIONS); these stubs just let the header preprocess.

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

#define RVMODEL_MTIMECMP_ADDRESS 0x02004000
#define RVMODEL_MTIME_ADDRESS    0x0200BFF8

#define RVMODEL_INTERRUPT_LATENCY    10
#define RVMODEL_TIMER_INT_SOON_DELAY 100

#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
