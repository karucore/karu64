//  vectest.c -- userspace RVV smoke test for V-enabled Linux on karu64.
//  Freestanding, static, no libc: it proves the kernel grants userspace the
//  vector unit (mstatus.VS managed per-task) by actually executing RVV ops in
//  U-mode -- vsetvli + vle32 + vadd.vv + vse32 over 16 e32 elements -- and
//  checking the result. If V were not enabled for userspace these would SIGILL,
//  so a printed [VECTEST] PASS is the proof. Built -march=rv64gcv.
typedef unsigned long  u64;
typedef unsigned int   u32;

static long sys_write(int fd, const void *buf, u64 n) {
    register long a0 __asm__("a0") = fd;
    register long a1 __asm__("a1") = (long)buf;
    register long a2 __asm__("a2") = (long)n;
    register long a7 __asm__("a7") = 64;    //  __NR_write
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return a0;
}
static void sys_exit(int code) {
    register long a0 __asm__("a0") = code;
    register long a7 __asm__("a7") = 93;    //  __NR_exit
    __asm__ volatile("ecall" :: "r"(a0), "r"(a7) : "memory");
    for (;;) { }
}
static void puts2(const char *s) { u64 n = 0; while (s[n]) n++; sys_write(1, s, n); }
static void putu(u32 v) {
    char b[12]; int i = 0;
    if (!v) { puts2("0"); return; }
    while (v) { b[i++] = "0123456789"[v % 10]; v /= 10; }
    char o[12]; int j = 0;
    while (i) o[j++] = b[--i];
    o[j] = 0; puts2(o);
}

#define N 16
void _start(void) {
    u32 a[N], b[N], c[N];
    for (u32 i = 0; i < N; i++) { a[i] = i + 1; b[i] = 100 + i; c[i] = 0; }

    //  Strip-mined e32/m1 add: process vl elements per iteration (vl = VLMAX =
    //  VLEN/32, e.g. 8 for VLEN=256) until all N are done -- the canonical RVV
    //  loop. Each pass: vsetvli + vle32 a,b + vadd.vv + vse32 c.
    u64 first_vl = 0;
    unsigned long n = N;
    u32 *pa = a, *pb = b, *pc = c;
    while (n > 0) {
        u64 vl;
        __asm__ volatile(
            "vsetvli %0, %1, e32, m1, ta, ma\n\t"
            "vle32.v v0, (%2)\n\t"
            "vle32.v v1, (%3)\n\t"
            "vadd.vv v2, v0, v1\n\t"
            "vse32.v v2, (%4)\n\t"
            : "=&r"(vl)
            : "r"(n), "r"(pa), "r"(pb), "r"(pc)
            : "memory");
        if (!first_vl) first_vl = vl;
        if (vl == 0) break;         //  guard (can't happen for n>0)
        pa += vl; pb += vl; pc += vl; n -= vl;
    }

    int ok = (n == 0);
    for (u32 i = 0; i < N; i++)
        if (c[i] != a[i] + b[i]) ok = 0;

    puts2("[VECTEST] VLEN/32 vl="); putu((u32)first_vl);
    puts2(" c[0]="); putu(c[0]);
    puts2(" c[15]="); putu(c[15]);
    if (ok) puts2("\n[VECTEST] PASS userspace RVV strip-mined vadd.vv over 16 e32\n");
    else    puts2("\n[VECTEST] FAIL\n");
    sys_exit(ok ? 0 : 1);
}
