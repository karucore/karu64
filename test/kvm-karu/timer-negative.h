/* SPDX-License-Identifier: GPL-2.0-only */
/* Test-proof controls only: never included in the normal fixture. */
#include "ucall_common.h"

#undef GUEST_DONE
#if KVM_TIMER_NEGATIVE == 1
/* A synchronization request must not satisfy the completion contract. */
#define GUEST_DONE() GUEST_SYNC(1)
#elif KVM_TIMER_NEGATIVE == 2
/* A DONE with an inconsistent interrupt count must also be rejected. */
#define GUEST_DONE() do { \
    WRITE_ONCE(vcpu_shared_data[guest_get_vcpuid()].nr_iter, 0); \
    ucall(UCALL_DONE, 0); \
} while (0)
#else
#error "select one of the maintained negative controls"
#endif
