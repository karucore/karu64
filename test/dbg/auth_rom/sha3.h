// SHA3-256 (FIPS 202) for the island ROM's 0x04 verifier and its host test.
// SPDX-License-Identifier: BSD-2-Clause
#ifndef KARU_AUTH_SHA3_H
#define KARU_AUTH_SHA3_H
#include <stddef.h>
#include <stdint.h>

void keccak_f1600(uint64_t a[25]);
/* out = SHA3-256(in[0..len-1]). The Keccak state is wiped before return. */
void sha3_256(uint8_t out[32], const uint8_t *in, size_t len);
/* Zero n bytes through a volatile pointer, so the compiler keeps the stores. */
void sha3_wipe(void *p, size_t n);

#endif
