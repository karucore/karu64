//	fugzip.h -- tiny gzip/deflate inflater for fu-boot

#ifndef FUGZIP_H
#define FUGZIP_H

#include <stdint.h>

/*
 * Return codes match puff.c for deflate errors where possible:
 *   2: input ended before the gzip/deflate stream was complete
 *   1: output space exhausted
 *   0: success
 *  <0: invalid gzip/deflate stream
 */
#define FUGZIP_ERR_GZIP		(-20)
#define FUGZIP_ERR_CRC		(-21)
#define FUGZIP_ERR_SIZE		(-22)

int fugzip_inflate(int (*get)(void *arg), void *arg, uint8_t *dest,
				   unsigned long *destlen, unsigned long *sourcelen);

#endif
