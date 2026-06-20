// core_portme.h -- karu64 bare-metal CoreMark port.
//
// The benchmark sources are consumed from an external CoreMark checkout; this
// header is intentionally local so the port uses HTIF I/O and Zicntr counters.

#ifndef KARU_CORE_PORTME_H
#define KARU_CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

#ifndef HAS_FLOAT
#define HAS_FLOAT 0
#endif
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
#ifndef HAS_PRINTF
#define HAS_PRINTF 0
#endif

typedef uint64_t CORE_TICKS;

#ifndef COMPILER_VERSION
#ifdef __GNUC__
#define COMPILER_VERSION "GCC " __VERSION__
#else
#define COMPILER_VERSION "unknown"
#endif
#endif

#ifndef FLAGS_STR
#define FLAGS_STR "karu64 bare-metal -O3"
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef int16_t   ee_s16;
typedef uint16_t  ee_u16;
typedef int32_t   ee_s32;
typedef double    ee_f32;
typedef uint8_t   ee_u8;
typedef uint32_t  ee_u32;
typedef uintptr_t ee_ptr_int;
typedef size_t    ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~((ee_ptr_int)3)))

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif
#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#endif
#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

#ifndef COREMARK_ITERATIONS
#define COREMARK_ITERATIONS 1
#endif
#ifndef ITERATIONS
#define ITERATIONS COREMARK_ITERATIONS
#endif
#ifndef TOTAL_DATA_SIZE
#define TOTAL_DATA_SIZE (2 * 1000)
#endif

// Used only to convert CoreMark's "seconds" field. The harness reports raw
// cycles and instret separately; one-iteration runs are not official CoreMark.
#ifndef COREMARK_HZ
#define COREMARK_HZ 100000000u
#endif

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
	ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
int ee_printf(const char *fmt, ...);

#endif
