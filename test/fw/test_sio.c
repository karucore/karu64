//  test_sio.c
//  2025-05-08  Markku-Juhani O. Saarinen <mjos@iki.fi>
//  === sio_generic.h (serial) IO

#include "sio_generic.h"

//  standard library (host / sim) serial IO
#include <stdio.h>

int sio_init() { return 0; }
void sio_close() { return; }
void sio_timeout(int wait_ms) { (void) wait_ms; return; }
int sio_getc() { return getc(stdin); }
size_t sio_read(void *buf, size_t count) {
    return fread(buf, 1, count, stdin); }
void sio_putc(int ch) { fputc(ch, stdout); }
size_t sio_write(const void *buf, size_t count) {
    return fwrite(buf, 1, count, stdout); }
void sio_puts(const char *s) { fputs(s, stdout); }
void sio_put_hex(uint32_t x, int n) {
    if (n > 0) { fprintf(stdout, "%0*X", n, (unsigned) (x));
    } else if (n < 0) { fprintf(stdout, "%*X", n, (unsigned) (x));
    } else { fprintf(stdout, "%X", (unsigned) (x)); }
}
void sio_put_dec(uint32_t x) { fprintf(stdout, "%u", (unsigned) (x)); }
