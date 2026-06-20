//	fugzip.c -- tiny gzip/deflate inflater for fu-boot
//
//	Altered from Mark Adler's puff.c 2.3 (21 Jan 2013): this version removes
//	setjmp, reads compressed bytes through a callback, writes directly to the
//	final destination, and wraps raw deflate with gzip header/trailer handling.
//
//	Copyright (C) 2002-2013 Mark Adler, all rights reserved
//
//	This software is provided 'as-is', without any express or implied
//	warranty.  In no event will the author be held liable for any damages
//	arising from the use of this software.
//
//	Permission is granted to anyone to use this software for any purpose,
//	including commercial applications, and to alter it and redistribute it
//	freely, subject to the following restrictions:
//
//	1. The origin of this software must not be misrepresented; you must not
//	   claim that you wrote the original software. If you use this software
//	   in a product, an acknowledgment in the product documentation would be
//	   appreciated but is not required.
//	2. Altered source versions must be plainly marked as such, and must not be
//	   misrepresented as being the original software.
//	3. This notice may not be removed or altered from any source distribution.

#include "fugzip.h"
#ifdef FUGZIP_DOTS
#include "sio_generic.h"
#endif

#define local static

#define MAXBITS		15
#define MAXLCODES	286
#define MAXDCODES	30
#define MAXCODES	(MAXLCODES + MAXDCODES)
#define FIXLCODES	288

struct huffman {
	short *count;
	short *symbol;
};

struct state {
	uint8_t *out;
	unsigned long outlen;
	unsigned long outcnt;

	unsigned long incnt;
	int bitbuf;
	int bitcnt;
	int err;

	int (*get)(void *arg);
	void *arg;
	uint32_t crc;
};

local uint32_t crc32_byte(uint32_t crc, uint8_t val)
{
	static const uint32_t tab[16] = {
		0x00000000UL, 0x1db71064UL, 0x3b6e20c8UL, 0x26d930acUL,
		0x76dc4190UL, 0x6b6b51f4UL, 0x4db26158UL, 0x5005713cUL,
		0xedb88320UL, 0xf00f9344UL, 0xd6d6a3e8UL, 0xcb61b38cUL,
		0x9b64c2b0UL, 0x86d3d2d4UL, 0xa00ae278UL, 0xbdbdf21cUL
	};

	crc ^= val;
	crc = (crc >> 4) ^ tab[crc & 0xf];
	return (crc >> 4) ^ tab[crc & 0xf];
}

local int pull(struct state *s)
{
	int c;

	if (s->err)
		return 0;
	c = s->get(s->arg);
	if (c < 0) {
		s->err = 2;
		return 0;
	}
	s->incnt++;
	return c & 0xff;
}

local int bits(struct state *s, int need)
{
	long val;

	val = s->bitbuf;
	while (s->bitcnt < need) {
		val |= (long)pull(s) << s->bitcnt;
		if (s->err)
			return 0;
		s->bitcnt += 8;
	}
	s->bitbuf = (int)(val >> need);
	s->bitcnt -= need;
	return (int)(val & ((1L << need) - 1));
}

local int put_byte(struct state *s, int val)
{
	if (s->outcnt == s->outlen)
		return 1;
	s->out[s->outcnt++] = (uint8_t)val;
	s->crc = crc32_byte(s->crc, (uint8_t)val);
#ifdef FUGZIP_DOTS
	if ((s->outcnt & 0xfffffUL) == 0)
		sio_putc('.');
#endif
	return 0;
}

local int stored(struct state *s)
{
	unsigned len;

	s->bitbuf = 0;
	s->bitcnt = 0;

	len = (unsigned)pull(s);
	len |= (unsigned)pull(s) << 8;
	if (s->err)
		return s->err;
	if (pull(s) != (int)(~len & 0xff) ||
		pull(s) != (int)((~len >> 8) & 0xff))
		return s->err ? s->err : -2;

	while (len--) {
		int c = pull(s);
		if (s->err)
			return s->err;
		if (put_byte(s, c))
			return 1;
	}
	return 0;
}

local int decode(struct state *s, const struct huffman *h)
{
	int len;
	int code;
	int first;
	int count;
	int index;
	int bitbuf;
	int left;
	short *next;

	bitbuf = s->bitbuf;
	left = s->bitcnt;
	code = first = index = 0;
	len = 1;
	next = h->count + 1;
	while (1) {
		while (left--) {
			code |= bitbuf & 1;
			bitbuf >>= 1;
			count = *next++;
			if (code - count < first) {
				s->bitbuf = bitbuf;
				s->bitcnt = (s->bitcnt - len) & 7;
				return h->symbol[index + (code - first)];
			}
			index += count;
			first += count;
			first <<= 1;
			code <<= 1;
			len++;
		}
		left = (MAXBITS + 1) - len;
		if (left == 0)
			break;
		bitbuf = pull(s);
		if (s->err)
			return -10;
		if (left > 8)
			left = 8;
	}
	return -10;
}

local int construct(struct huffman *h, const short *length, int n)
{
	int symbol;
	int len;
	int left;
	short offs[MAXBITS + 1];

	for (len = 0; len <= MAXBITS; len++)
		h->count[len] = 0;
	for (symbol = 0; symbol < n; symbol++)
		(h->count[length[symbol]])++;
	if (h->count[0] == n)
		return 0;

	left = 1;
	for (len = 1; len <= MAXBITS; len++) {
		left <<= 1;
		left -= h->count[len];
		if (left < 0)
			return left;
	}

	offs[1] = 0;
	for (len = 1; len < MAXBITS; len++)
		offs[len + 1] = offs[len] + h->count[len];

	for (symbol = 0; symbol < n; symbol++)
		if (length[symbol] != 0)
			h->symbol[offs[length[symbol]]++] = symbol;

	return left;
}

local int codes(struct state *s, const struct huffman *lencode,
				const struct huffman *distcode)
{
	int symbol;
	int len;
	unsigned dist;
	static const short lens[29] = {
		3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
		35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
	static const short lext[29] = {
		0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
		3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
	static const short dists[30] = {
		1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
		257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
		8193, 12289, 16385, 24577};
	static const short dext[30] = {
		0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
		7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

	do {
		symbol = decode(s, lencode);
		if (symbol < 0)
			return s->err ? s->err : symbol;
		if (symbol < 256) {
			if (put_byte(s, symbol))
				return 1;
		} else if (symbol > 256) {
			int extra;

			symbol -= 257;
			if (symbol >= 29)
				return -10;
			extra = bits(s, lext[symbol]);
			if (s->err)
				return s->err;
			len = lens[symbol] + extra;

			symbol = decode(s, distcode);
			if (symbol < 0)
				return s->err ? s->err : symbol;
			if (symbol >= 30)
				return -10;
			extra = bits(s, dext[symbol]);
			if (s->err)
				return s->err;
			dist = dists[symbol] + extra;
			if (dist > s->outcnt)
				return -11;

			while (len--) {
				int val;

				if (s->outcnt == s->outlen)
					return 1;
				val = s->out[s->outcnt - dist];
				if (put_byte(s, val))
					return 1;
			}
		}
	} while (symbol != 256);

	return 0;
}

local int fixed(struct state *s)
{
	static int virgin = 1;
	static short lencnt[MAXBITS + 1], lensym[FIXLCODES];
	static short distcnt[MAXBITS + 1], distsym[MAXDCODES];
	static struct huffman lencode, distcode;

	if (virgin) {
		int symbol;
		short lengths[FIXLCODES];

		lencode.count = lencnt;
		lencode.symbol = lensym;
		distcode.count = distcnt;
		distcode.symbol = distsym;

		for (symbol = 0; symbol < 144; symbol++)
			lengths[symbol] = 8;
		for (; symbol < 256; symbol++)
			lengths[symbol] = 9;
		for (; symbol < 280; symbol++)
			lengths[symbol] = 7;
		for (; symbol < FIXLCODES; symbol++)
			lengths[symbol] = 8;
		construct(&lencode, lengths, FIXLCODES);

		for (symbol = 0; symbol < MAXDCODES; symbol++)
			lengths[symbol] = 5;
		construct(&distcode, lengths, MAXDCODES);

		virgin = 0;
	}

	return codes(s, &lencode, &distcode);
}

local int dynamic(struct state *s)
{
	int nlen, ndist, ncode;
	int index;
	int err;
	short lengths[MAXCODES];
	short lencnt[MAXBITS + 1], lensym[MAXLCODES];
	short distcnt[MAXBITS + 1], distsym[MAXDCODES];
	struct huffman lencode, distcode;
	static const short order[19] =
		{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

	lencode.count = lencnt;
	lencode.symbol = lensym;
	distcode.count = distcnt;
	distcode.symbol = distsym;

	nlen = bits(s, 5) + 257;
	ndist = bits(s, 5) + 1;
	ncode = bits(s, 4) + 4;
	if (s->err)
		return s->err;
	if (nlen > MAXLCODES || ndist > MAXDCODES)
		return -3;

	for (index = 0; index < ncode; index++) {
		lengths[order[index]] = bits(s, 3);
		if (s->err)
			return s->err;
	}
	for (; index < 19; index++)
		lengths[order[index]] = 0;

	err = construct(&lencode, lengths, 19);
	if (err != 0)
		return -4;

	index = 0;
	while (index < nlen + ndist) {
		int symbol;
		int len;

		symbol = decode(s, &lencode);
		if (symbol < 0)
			return s->err ? s->err : symbol;
		if (symbol < 16) {
			lengths[index++] = symbol;
		} else {
			len = 0;
			if (symbol == 16) {
				if (index == 0)
					return -5;
				len = lengths[index - 1];
				symbol = 3 + bits(s, 2);
			} else if (symbol == 17) {
				symbol = 3 + bits(s, 3);
			} else {
				symbol = 11 + bits(s, 7);
			}
			if (s->err)
				return s->err;
			if (index + symbol > nlen + ndist)
				return -6;
			while (symbol--)
				lengths[index++] = len;
		}
	}

	if (lengths[256] == 0)
		return -9;

	err = construct(&lencode, lengths, nlen);
	if (err && (err < 0 || nlen != lencode.count[0] + lencode.count[1]))
		return -7;

	err = construct(&distcode, lengths + nlen, ndist);
	if (err && (err < 0 || ndist != distcode.count[0] + distcode.count[1]))
		return -8;

	return codes(s, &lencode, &distcode);
}

local int gzip_skip_zero_string(struct state *s)
{
	int c;

	do {
		c = pull(s);
		if (s->err)
			return s->err;
	} while (c != 0);
	return 0;
}

local uint32_t gzip_pull_le32(struct state *s)
{
	uint32_t val;

	val = (uint32_t)pull(s);
	val |= (uint32_t)pull(s) << 8;
	val |= (uint32_t)pull(s) << 16;
	val |= (uint32_t)pull(s) << 24;
	return val;
}

local int gzip_header(struct state *s)
{
	int flags, i, xlen;

	if (pull(s) != 0x1f || pull(s) != 0x8b)
		return s->err ? s->err : FUGZIP_ERR_GZIP;
	if (pull(s) != 8)
		return s->err ? s->err : FUGZIP_ERR_GZIP;
	flags = pull(s);
	if (s->err)
		return s->err;
	if (flags & 0xe0)
		return FUGZIP_ERR_GZIP;

	for (i = 0; i < 6; i++)
		pull(s);				//	mtime[4], xfl, os
	if (s->err)
		return s->err;

	if (flags & 4) {
		xlen = pull(s);
		xlen |= pull(s) << 8;
		if (s->err)
			return s->err;
		while (xlen--)
			pull(s);
		if (s->err)
			return s->err;
	}
	if ((flags & 8) && gzip_skip_zero_string(s))
		return s->err;
	if ((flags & 16) && gzip_skip_zero_string(s))
		return s->err;
	if (flags & 2) {
		pull(s);
		pull(s);
		if (s->err)
			return s->err;
	}
	return 0;
}

int fugzip_inflate(int (*get)(void *arg), void *arg, uint8_t *dest,
				   unsigned long *destlen, unsigned long *sourcelen)
{
	struct state s;
	int last, type;
	int err;

	s.out = dest;
	s.outlen = *destlen;
	s.outcnt = 0;
	s.incnt = 0;
	s.bitbuf = 0;
	s.bitcnt = 0;
	s.err = 0;
	s.get = get;
	s.arg = arg;
	s.crc = 0xffffffffUL;

	err = gzip_header(&s);
	if (err == 0) {
		do {
			last = bits(&s, 1);
			type = bits(&s, 2);
			if (s.err) {
				err = s.err;
				break;
			}
			err = type == 0 ? stored(&s) :
				  (type == 1 ? fixed(&s) :
				   (type == 2 ? dynamic(&s) : -1));
			if (err != 0)
				break;
		} while (!last);
	}

	if (err == 0) {
		uint32_t want_crc, want_size;

		s.bitbuf = 0;
		s.bitcnt = 0;
		want_crc = gzip_pull_le32(&s);
		want_size = gzip_pull_le32(&s);
		if (s.err)
			err = s.err;
		else if ((s.crc ^ 0xffffffffUL) != want_crc)
			err = FUGZIP_ERR_CRC;
		else if ((uint32_t)s.outcnt != want_size)
			err = FUGZIP_ERR_SIZE;
	}

	*destlen = s.outcnt;
	if (sourcelen != 0)
		*sourcelen = s.incnt;
	return err;
}
