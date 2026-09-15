// SPDX-License-Identifier: BSD-3-Clause
// Shared karu64 HTIF transport, with an initially inactive reference timer.
#include "rvmodel_common.h"

#ifdef RVMODEL_HTIF_CLINT
// Profile verification platform: the real one-hart CLINT in HTIF_TB_CLINT.
// Declare these before Sail's overrides so both ELFs select timer-capable
// test bodies and retain the same code/data layout.
#define RVMODEL_MTIME_ADDRESS    0x0200bff8
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000
#define RVMODEL_MSIP_ADDRESS     0x02000000
// One timer tick per RTL cycle. Allow privilege entry and the reservation
// setup to finish before the timer-resume tests take their interrupt.
#undef RVMODEL_TIMER_INT_SOON_DELAY
#define RVMODEL_TIMER_INT_SOON_DELAY 1000
#undef RVMODEL_SET_MSW_INT
#undef RVMODEL_CLR_MSW_INT
#define RVMODEL_SET_MSW_INT(_R1, _R2) \
  LI(_R1, RVMODEL_MSIP_ADDRESS); LI(_R2, 1); sw _R2, 0(_R1);
#define RVMODEL_CLR_MSW_INT(_R1, _R2) \
  LI(_R1, RVMODEL_MSIP_ADDRESS); sw zero, 0(_R1);
#endif

#ifdef RVMODEL_HTIF_EXTIRQ
// Independent external-input latches in HTIF_TB_EXTIRQ. The linker places
// these symbols in unused space in the uncacheable HTIF page. Unlike a CSR
// pending-bit write, each device write changes the core's actual IRQ pin.
#undef RVMODEL_SET_MEXT_INT
#undef RVMODEL_CLR_MEXT_INT
#undef RVMODEL_SET_SEXT_INT
#undef RVMODEL_CLR_SEXT_INT
#define RVMODEL_SET_MEXT_INT(_R1, _R2) \
  LA(_R1, karu_htif_meip); LI(_R2, 1); sw _R2, 0(_R1);
#define RVMODEL_CLR_MEXT_INT(_R1, _R2) \
  LA(_R1, karu_htif_meip); sw zero, 0(_R1);
#define RVMODEL_SET_SEXT_INT(_R1, _R2) \
  LA(_R1, karu_htif_seip); LI(_R2, 1); sw _R2, 0(_R1);
#define RVMODEL_CLR_SEXT_INT(_R1, _R2) \
  LA(_R1, karu_htif_seip); sw zero, 0(_R1);
#endif

// Initialize Sail's machine timer in the out-of-line platform boot section,
// matching the DUT harness's initially inactive MTIP. Legacy RAM-only
// configurations leave timer MMIO undeclared in both ELF variants.
#ifndef RVTEST_SELFCHECK
// Include the standard reference overrides before defining the boot hook;
// the framework's later include is guarded and leaves this hook intact.
#include "sail_macros.h"
#undef RVMODEL_BOOT
#define RVMODEL_BOOT \
  LI(t0, SAIL_MTIMECMP_ADDRESS); \
  LI(t1, -1); \
  sd t1, 0(t0);
#endif
