// vcu118_fuboot.c -- serial monitor / flash gzip loader for VCU118 DDR.

#include <stdint.h>
#include <stddef.h>
#include "fugzip.h"

#ifndef FUBOOT_VER
#define FUBOOT_VER "vcu118-0.1"
#endif
#ifndef FUBOOT_LOADADDR
#define FUBOOT_LOADADDR 0x80100000UL
#endif
#ifndef FUBOOT_GZ_LOADADDR
#define FUBOOT_GZ_LOADADDR 0x80000000UL
#endif
#ifndef FUBOOT_DTBADDR
#define FUBOOT_DTBADDR 0x81b00000UL
#endif
#ifndef FUBOOT_FLASH_OFFSET
#define FUBOOT_FLASH_OFFSET 0x02000000UL
#endif
#ifndef FUBOOT_DDR_SIZE
#define FUBOOT_DDR_SIZE 0x10000000UL
#endif

#define UART_BASE 0x10000000UL
#define UART ((volatile uint8_t *)UART_BASE)
#define UART_RBR 0
#define UART_THR 0
#define UART_IER 1
#define UART_FCR 2
#define UART_LCR 3
#define UART_LSR 5
#define UART_SCR 7
#define UART_LSR_DR 0x01
#define UART_LSR_THRE 0x20
#define UART_LCR_8N1 0x03

#define FLASH_CTRL  ((volatile uint64_t *)0x12000000UL)
#define FLASH_DATA  ((volatile uint64_t *)0x12000008UL)
#define FLASH_DIV   ((volatile uint64_t *)0x12000010UL)
#define FLASH_BUSY  0x1
#define FLASH_DONE  0x2
#define FLASH_CS_N  0x1
#define FLASH_CLR   0x2

#define X_SOH 0x01
#define X_STX 0x02
#define X_EOT 0x04
#define X_ACK 0x06
#define X_NAK 0x15
#define X_CAN 0x18
#define X_CRCRQ 'C'

static uintptr_t loadaddr = FUBOOT_LOADADDR;

static void sio_putc(int ch)
{
	while (!(UART[UART_LSR] & UART_LSR_THRE)) { }
	UART[UART_THR] = (uint8_t)ch;
}

static void sio_puts(const char *s)
{
	while (*s)
		sio_putc(*s++);
}

static int sio_getc(void)
{
	if (UART[UART_LSR] & UART_LSR_DR) {
		int ch = UART[UART_RBR];
		UART[UART_SCR] = 0;
		return ch;
	}
	return -1;
}

static int sio_getc_block(void)
{
	int c;
	while ((c = sio_getc()) < 0) { }
	return c;
}

static void sio_put_hex(uint32_t x, int n)
{
	int i;
	for (i = (n - 1) * 4; i >= 0; i -= 4) {
		unsigned d = (x >> i) & 0xf;
		sio_putc(d < 10 ? '0' + d : 'A' + d - 10);
	}
}

static void sio_put_dec(uint32_t x)
{
	char buf[10];
	int n = 0;
	if (x == 0) {
		sio_putc('0');
		return;
	}
	while (x != 0 && n < (int)sizeof(buf)) {
		uint32_t q = x / 10;
		buf[n++] = '0' + (char)(x - q * 10);
		x = q;
	}
	while (n)
		sio_putc(buf[--n]);
}

static uintptr_t parse_hex(const char *s)
{
	uintptr_t v = 0;
	while (*s == ' ')
		s++;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	for (;;) {
		char c = *s++;
		uintptr_t d;
		if (c >= '0' && c <= '9') d = (uintptr_t)(c - '0');
		else if (c >= 'a' && c <= 'f') d = (uintptr_t)(c - 'a' + 10);
		else if (c >= 'A' && c <= 'F') d = (uintptr_t)(c - 'A' + 10);
		else break;
		v = (v << 4) | d;
	}
	return v;
}

static char *skip_hex_arg(char *s)
{
	while (*s == ' ')
		s++;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	while ((*s >= '0' && *s <= '9') || (*s >= 'a' && *s <= 'f') ||
		   (*s >= 'A' && *s <= 'F'))
		s++;
	while (*s == ' ')
		s++;
	return s;
}

static int cmd_is(const char *p, const char *cmd)
{
	while (*cmd) {
		if (*p++ != *cmd++)
			return 0;
	}
	return *p == 0 || *p == ' ';
}

static char *cmd_args(char *p)
{
	while (*p && *p != ' ')
		p++;
	while (*p == ' ')
		p++;
	return p;
}

static int readline(char *buf, int max)
{
	int n = 0;
	for (;;) {
		int c = sio_getc_block();
		if (c == '\r' || c == '\n') {
			sio_puts("\r\n");
			buf[n] = 0;
			return n;
		}
		if ((c == 0x08 || c == 0x7f) && n > 0) {
			n--;
			sio_puts("\b \b");
		} else if (c >= ' ' && c < 0x7f && n < max - 1) {
			buf[n++] = (char)c;
			sio_putc(c);
		}
	}
}

static void put_hex64(uint64_t x)
{
	sio_put_hex((uint32_t)(x >> 32), 8);
	sio_put_hex((uint32_t)x, 8);
}

static void mem_dump(uintptr_t addr, uint32_t words)
{
	uint32_t i;
	addr &= ~(uintptr_t)7;
	if (words == 0)
		words = 16;
	if (words > 256)
		words = 256;
	for (i = 0; i < words; i++) {
		if ((i & 3) == 0) {
			sio_put_hex((uint32_t)addr, 8);
			sio_putc(':');
		}
		sio_putc(' ');
		put_hex64(*(volatile uint64_t *)addr);
		addr += 8;
		if ((i & 3) == 3 || i + 1 == words)
			sio_puts("\r\n");
	}
}

static void mem_write(uintptr_t addr, uint64_t val)
{
	*(volatile uint64_t *)(addr & ~(uintptr_t)7) = val;
}

static unsigned long load_limit(uintptr_t addr)
{
	uintptr_t lo = 0x80000000UL;
	uintptr_t hi = lo + (uintptr_t)FUBOOT_DDR_SIZE;
	if (addr >= lo && addr < hi)
		return (unsigned long)(hi - addr);
	return 0xffffffffUL;
}

static uint16_t crc16_xmodem(const uint8_t *p, int n)
{
	uint16_t c = 0;
	int i, k;
	for (i = 0; i < n; i++) {
		c ^= (uint16_t)p[i] << 8;
		for (k = 0; k < 8; k++)
			c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) :
							   (uint16_t)(c << 1);
	}
	return c;
}

struct xmodem_stream {
	uint8_t buf[1024];
	uint8_t blk;
	int pos, len, eof, bad, started, ack_pending;
	long total;
};

static void xmodem_begin(struct xmodem_stream *x)
{
	x->blk = 1;
	x->pos = x->len = x->eof = x->bad = x->started = x->ack_pending = 0;
	x->total = 0;
}

static int xmodem_fill(struct xmodem_stream *x)
{
	int c, i;
	if (x->bad || x->eof)
		return 0;
	if (!x->started) {
		sio_putc(X_CRCRQ);
		c = sio_getc_block();
		x->started = 1;
	} else {
		c = sio_getc_block();
	}
	for (;;) {
		int blksz, b, bc, ch, cl, bad = 0;
		uint16_t crc;
		if (c == X_EOT) {
			sio_putc(X_ACK);
			x->eof = 1;
			return 0;
		}
		if (c == X_CAN) {
			x->bad = 1;
			return -1;
		}
		if (c == X_SOH) blksz = 128;
		else if (c == X_STX) blksz = 1024;
		else {
			c = sio_getc_block();
			continue;
		}
		b = sio_getc_block();
		bc = sio_getc_block();
		for (i = 0; i < blksz; i++)
			x->buf[i] = (uint8_t)sio_getc_block();
		ch = sio_getc_block();
		cl = sio_getc_block();
		crc = (uint16_t)((ch << 8) | cl);
		if ((uint8_t)b != (uint8_t)~(uint8_t)bc)
			bad = 1;
		if (!bad && (uint8_t)b == x->blk && crc16_xmodem(x->buf, blksz) == crc) {
			x->pos = 0;
			x->len = blksz;
			x->total += blksz;
			x->blk++;
			x->ack_pending = 1;
			return 1;
		}
		if (!bad && (uint8_t)b == (uint8_t)(x->blk - 1))
			sio_putc(X_ACK);
		else
			sio_putc(X_NAK);
		c = sio_getc_block();
	}
}

static int xmodem_get(void *arg)
{
	struct xmodem_stream *x = (struct xmodem_stream *)arg;
	if (x->pos >= x->len) {
		if (x->ack_pending) {
			sio_putc(X_ACK);
			x->ack_pending = 0;
		}
		if (xmodem_fill(x) <= 0)
			return -1;
	}
	return x->buf[x->pos++];
}

static long xmodem_recv(uint8_t *dst)
{
	struct xmodem_stream x;
	long total = 0;
	int c;
	xmodem_begin(&x);
	while ((c = xmodem_get(&x)) >= 0)
		dst[total++] = (uint8_t)c;
	return x.bad ? -1 : total;
}

static int xmodem_recv_gzip(uint8_t *dst, unsigned long limit,
							unsigned long *outlen, unsigned long *gzlen)
{
	struct xmodem_stream x;
	int err;
	*outlen = limit;
	*gzlen = 0;
	xmodem_begin(&x);
	err = fugzip_inflate(xmodem_get, &x, dst, outlen, gzlen);
	if (x.ack_pending)
		sio_putc(X_ACK);
	return err;
}

static void flash_wait(void)
{
	while (*FLASH_CTRL & FLASH_BUSY) { }
}

static uint8_t flash_xfer(uint8_t v)
{
	*FLASH_DATA = v;
	flash_wait();
	while (!(*FLASH_CTRL & FLASH_DONE)) { }
	v = (uint8_t)*FLASH_DATA;
	*FLASH_CTRL = FLASH_CLR;
	return v;
}

struct flash_stream {
	uint32_t off;
	unsigned long cnt;
};

static void flash_begin(uint32_t off)
{
	*FLASH_DIV = 4;
	*FLASH_CTRL = FLASH_CS_N | FLASH_CLR;
	*FLASH_CTRL = FLASH_CLR;
	flash_xfer(0x03);
	flash_xfer((uint8_t)(off >> 16));
	flash_xfer((uint8_t)(off >> 8));
	flash_xfer((uint8_t)off);
}

static void flash_end(void)
{
	*FLASH_CTRL = FLASH_CS_N | FLASH_CLR;
}

static int flash_get(void *arg)
{
	struct flash_stream *f = (struct flash_stream *)arg;
	f->cnt++;
	return flash_xfer(0);
}

static int flash_recv_gzip(uint32_t off, uint8_t *dst, unsigned long limit,
						   unsigned long *outlen, unsigned long *gzlen)
{
	struct flash_stream f;
	int err;
	f.off = off;
	f.cnt = 0;
	*outlen = limit;
	*gzlen = 0;
	flash_begin(f.off);
	err = fugzip_inflate(flash_get, &f, dst, outlen, gzlen);
	flash_end();
	return err;
}

static void go(uintptr_t addr)
{
	void (*app)(void) = (void (*)(void))addr;
	sio_puts("## Starting application at 0x");
	sio_put_hex((uint32_t)addr, 8);
	sio_puts(" ...\r\n");
	asm volatile("fence.i" ::: "memory");
	app();
}

static void boot(uintptr_t addr, uintptr_t dtb)
{
	void (*app)(uintptr_t, uintptr_t) = (void (*)(uintptr_t, uintptr_t))addr;
	sio_puts("## Booting image at 0x");
	sio_put_hex((uint32_t)addr, 8);
	sio_puts(" with FDT at 0x");
	sio_put_hex((uint32_t)dtb, 8);
	sio_puts(" ...\r\n");
	asm volatile("fence.i" ::: "memory");
	app(0, dtb);
}

#ifdef FUBOOT_AUTOBOOT
//	Self-contained boot: OpenSBI + U-Boot + the control DTB are baked into the boot ROM
//	(see flow/build_fuboot_rom.sh + flow/boot/fuboot_blobs.h, generated). On reset fu-boot
//	copies each image from ROM to its DDR run address and jumps into OpenSBI, which jumps
//	to U-Boot (FW_JUMP_ADDR=0x8020_0000), whose baked bootcmd TFTP-netboots Linux. A 2 s
//	key-press window drops to the interactive monitor instead (JTAG-load debug fallback).
#include "fuboot_blobs.h"

#define ROM_BASE_ADDR     0x00001000UL
#define OS_LOADADDR       0x80000000UL	/* OpenSBI fw_jump entry */
#define UBOOT_LOADADDR    0x80200000UL	/* OpenSBI FW_JUMP_ADDR -> U-Boot */
#define CLINT_MTIME_ADDR  0x0200BFF8UL

static uint64_t rd_mtime(void)
{
	return *(volatile uint64_t *)CLINT_MTIME_ADDR;
}

//	64-bit-word copy ROM->DDR (both are 8-byte-wide memories); rounds up to a word.
static void rom_copy(uintptr_t dst, uintptr_t src, unsigned long n)
{
	volatile uint64_t *d = (volatile uint64_t *)dst;
	volatile uint64_t *s = (volatile uint64_t *)src;
	unsigned long w = (n + 7) / 8, i;
	for (i = 0; i < w; i++)
		d[i] = s[i];
}

static void autoboot(void)
{
	sio_puts("## fu-boot: copying boot chain from ROM to DDR\r\n");
	sio_puts("##   OpenSBI -> 0x80000000 (");
	sio_put_dec((uint32_t)FUBOOT_OPENSBI_SIZE);
	sio_puts(" B)\r\n");
	rom_copy(OS_LOADADDR, ROM_BASE_ADDR + FUBOOT_OPENSBI_OFF, FUBOOT_OPENSBI_SIZE);
	sio_puts("##   U-Boot  -> 0x80200000 (");
	sio_put_dec((uint32_t)FUBOOT_UBOOT_SIZE);
	sio_puts(" B)\r\n");
	rom_copy(UBOOT_LOADADDR, ROM_BASE_ADDR + FUBOOT_UBOOT_OFF, FUBOOT_UBOOT_SIZE);
	sio_puts("##   DTB     -> 0x81b00000 (");
	sio_put_dec((uint32_t)FUBOOT_DTB_SIZE);
	sio_puts(" B)\r\n");
	rom_copy((uintptr_t)FUBOOT_DTBADDR, ROM_BASE_ADDR + FUBOOT_DTB_OFF, FUBOOT_DTB_SIZE);
	boot(OS_LOADADDR, (uintptr_t)FUBOOT_DTBADDR);
}
#endif

static void help(void)
{
	sio_puts("help                      show commands\r\n");
	sio_puts("loadx [addr]              receive binary over XMODEM\r\n");
	sio_puts("loadgz [addr]             receive gzip over XMODEM and inflate\r\n");
	sio_puts("flashgz [off] [addr]      inflate gzip from config flash offset\r\n");
	sio_puts("md [addr] [n]             dump n 64-bit words\r\n");
	sio_puts("mw <addr> <value64>       write one 64-bit word\r\n");
	sio_puts("go [addr]                 jump to addr\r\n");
	sio_puts("boot [addr] [dtb]         jump with a0=0, a1=dtb\r\n");
}

int main(void)
{
	char line[80], *p;

	UART[UART_LCR] = UART_LCR_8N1;
	UART[UART_IER] = 0;
	UART[UART_FCR] = 1;

	sio_puts("\r\n\r\nfu-boot " FUBOOT_VER " -- karu64 VCU118 DDR monitor\r\n");

#ifdef FUBOOT_AUTOBOOT
	sio_puts("## auto-boot in 2s -- press any key for fu-boot monitor\r\n");
	{
		uint64_t t_end = rd_mtime() + 2000000ULL;	/* 2 s @ 1 MHz CLINT mtime */
		int escape = 0;
		while (rd_mtime() < t_end) {
			if (sio_getc() >= 0) { escape = 1; break; }
		}
		if (!escape)
			autoboot();		/* copies + jumps into OpenSBI; does not return */
		sio_puts("## entered fu-boot monitor\r\n");
	}
#endif
	help();

	for (;;) {
		sio_puts("fu-boot> ");
		readline(line, sizeof(line));
		for (p = line; *p == ' '; p++) { }

		if (cmd_is(p, "loadx")) {
			char *a = cmd_args(p);
			long n;
			if (*a)
				loadaddr = parse_hex(a);
			sio_puts("## Ready for binary XMODEM at 0x");
			sio_put_hex((uint32_t)loadaddr, 8);
			sio_puts("\r\n");
			n = xmodem_recv((uint8_t *)loadaddr);
			if (n < 0)
				sio_puts("## loadx FAILED\r\n");
			else {
				sio_puts("## received ");
				sio_put_dec((uint32_t)n);
				sio_puts(" bytes\r\n");
			}
		} else if (cmd_is(p, "loadgz")) {
			char *a = cmd_args(p);
			uintptr_t addr = *a ? parse_hex(a) : (uintptr_t)FUBOOT_GZ_LOADADDR;
			unsigned long outlen, gzlen;
			int err;
			sio_puts("## Ready for gzip XMODEM at 0x");
			sio_put_hex((uint32_t)addr, 8);
			sio_puts("\r\n");
			err = xmodem_recv_gzip((uint8_t *)addr, load_limit(addr), &outlen, &gzlen);
			if (err) {
				sio_puts("## loadgz FAILED err=");
				if (err < 0) {
					sio_putc('-');
					err = -err;
				}
				sio_put_dec((uint32_t)err);
				sio_puts("\r\n");
			} else {
				loadaddr = addr;
				sio_puts("## decompressed ");
				sio_put_dec((uint32_t)outlen);
				sio_puts(" bytes from ");
				sio_put_dec((uint32_t)gzlen);
				sio_puts(" gzip bytes\r\n");
			}
		} else if (cmd_is(p, "flashgz")) {
			char *a = cmd_args(p);
			uint32_t off = *a ? (uint32_t)parse_hex(a) : (uint32_t)FUBOOT_FLASH_OFFSET;
			uintptr_t addr;
			unsigned long outlen, gzlen;
			int err;
			a = skip_hex_arg(a);
			addr = *a ? parse_hex(a) : (uintptr_t)FUBOOT_GZ_LOADADDR;
			sio_puts("## Loading gzip from flash offset 0x");
			sio_put_hex(off, 8);
			sio_puts(" to 0x");
			sio_put_hex((uint32_t)addr, 8);
			sio_puts("\r\n");
			err = flash_recv_gzip(off, (uint8_t *)addr, load_limit(addr), &outlen, &gzlen);
			if (err) {
				sio_puts("## flashgz FAILED err=");
				if (err < 0) {
					sio_putc('-');
					err = -err;
				}
				sio_put_dec((uint32_t)err);
				sio_puts("\r\n");
			} else {
				loadaddr = addr;
				sio_puts("## decompressed ");
				sio_put_dec((uint32_t)outlen);
				sio_puts(" bytes from ");
				sio_put_dec((uint32_t)gzlen);
				sio_puts(" flash bytes\r\n");
			}
		} else if (cmd_is(p, "md")) {
			char *a = cmd_args(p);
			uintptr_t addr = *a ? parse_hex(a) : loadaddr;
			uint32_t words;
			a = skip_hex_arg(a);
			words = *a ? (uint32_t)parse_hex(a) : 16;
			mem_dump(addr, words);
		} else if (cmd_is(p, "mw")) {
			char *a = cmd_args(p);
			uintptr_t addr = parse_hex(a);
			uint64_t hi, lo;
			a = skip_hex_arg(a);
			lo = parse_hex(a);
			hi = 0;
			mem_write(addr, (hi << 32) | lo);
			sio_puts("OK\r\n");
		} else if (cmd_is(p, "go")) {
			char *a = cmd_args(p);
			go(*a ? parse_hex(a) : loadaddr);
		} else if (cmd_is(p, "boot")) {
			char *a = cmd_args(p);
			uintptr_t addr = *a ? parse_hex(a) : loadaddr;
			uintptr_t dtb;
			a = skip_hex_arg(a);
			dtb = *a ? parse_hex(a) : (uintptr_t)FUBOOT_DTBADDR;
			boot(addr, dtb);
		} else if (cmd_is(p, "h") || cmd_is(p, "help")) {
			help();
		} else if (*p) {
			sio_puts("unknown command; try help\r\n");
		}
	}
}
