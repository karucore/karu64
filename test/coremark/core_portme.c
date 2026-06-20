// core_portme.c -- karu64 bare-metal CoreMark port.

#include <stdarg.h>
#include <stdint.h>
#include "sio_generic.h"
#include "coremark.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static CORE_TICKS start_cycle, stop_cycle;
static CORE_TICKS start_instret, stop_instret;

static inline uint64_t rdcycle64(void)
{
	uint64_t x;
	asm volatile("rdcycle %0" : "=r"(x));
	return x;
}

static inline uint64_t rdinstret64(void)
{
	uint64_t x;
	asm volatile("rdinstret %0" : "=r"(x));
	return x;
}

void start_time(void)
{
	start_instret = rdinstret64();
	start_cycle = rdcycle64();
}

void stop_time(void)
{
	stop_cycle = rdcycle64();
	stop_instret = rdinstret64();
}

CORE_TICKS get_time(void)
{
	return stop_cycle - start_cycle;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
	return (secs_ret)(ticks / (CORE_TICKS)COREMARK_HZ);
}

static int put_ch(int ch)
{
	sio_putc(ch);
	return 1;
}

static int put_str(const char *s)
{
	int n = 0;
	if (!s)
		s = "(null)";
	while (*s) {
		sio_putc(*s++);
		n++;
	}
	return n;
}

static int put_u(uint64_t v, unsigned base, unsigned width, int zero)
{
	char buf[32];
	unsigned n = 0, out = 0;
	const char *digits = "0123456789abcdef";

	if (v == 0) {
		buf[n++] = '0';
	} else {
		while (v) {
			buf[n++] = digits[v % base];
			v /= base;
		}
	}
	while (n < width) {
		sio_putc(zero ? '0' : ' ');
		out++;
		width--;
	}
	while (n) {
		sio_putc(buf[--n]);
		out++;
	}
	return (int)out;
}

static int put_s(int64_t v)
{
	if (v < 0)
		return put_ch('-') + put_u((uint64_t)(-v), 10, 0, 0);
	return put_u((uint64_t)v, 10, 0, 0);
}

int ee_printf(const char *fmt, ...)
{
	va_list ap;
	int out = 0;

	va_start(ap, fmt);
	while (*fmt) {
		if (*fmt != '%') {
			out += put_ch(*fmt++);
			continue;
		}

		fmt++;
		if (*fmt == '%') {
			out += put_ch(*fmt++);
			continue;
		}

		int zero = 0;
		unsigned width = 0;
		int long_arg = 0;

		if (*fmt == '0') {
			zero = 1;
			fmt++;
		}
		while (*fmt >= '0' && *fmt <= '9') {
			width = width * 10 + (unsigned)(*fmt - '0');
			fmt++;
		}
		if (*fmt == 'l') {
			long_arg = 1;
			fmt++;
		}

		switch (*fmt++) {
		case 'c':
			out += put_ch(va_arg(ap, int));
			break;
		case 's':
			out += put_str(va_arg(ap, const char *));
			break;
		case 'd':
		case 'i':
			out += long_arg ? put_s(va_arg(ap, long)) : put_s(va_arg(ap, int));
			break;
		case 'u':
			out += long_arg ? put_u(va_arg(ap, unsigned long), 10, width, zero)
							: put_u(va_arg(ap, unsigned int), 10, width, zero);
			break;
		case 'x':
			out += long_arg ? put_u(va_arg(ap, unsigned long), 16, width, zero)
							: put_u(va_arg(ap, unsigned int), 16, width, zero);
			break;
		default:
			out += put_ch('?');
			break;
		}
	}
	va_end(ap);
	return out;
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
	(void)argc;
	(void)argv;

	if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
		ee_printf("ERROR! ee_ptr_int does not hold a pointer\n");
	if (sizeof(ee_u32) != 4)
		ee_printf("ERROR! ee_u32 is not 32-bit\n");
	p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
	uint64_t cycles = stop_cycle - start_cycle;
	uint64_t instret = stop_instret - start_instret;

	p->portable_id = 0;
	ee_printf("[KARU] rdcycle_delta : %lu\n", (unsigned long)cycles);
	ee_printf("[KARU] rdinstret_delta: %lu\n", (unsigned long)instret);
	if (instret != 0) {
		uint64_t cpi_milli = (cycles * 1000u) / instret;
		ee_printf("[KARU] cycles/inst x1000: %lu\n", (unsigned long)cpi_milli);
	}
	if (time_in_secs(cycles) < 10)
		ee_printf("[KARU] note: COREMARK_ITERATIONS=%d is a short profiling run, not an official 10s CoreMark score.\n",
				  (int)seed4_volatile);
}
