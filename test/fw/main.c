//  main.c
//  2025-05-08  Markku-Juhani O. Saarinen <mjos@iki.fi>
//  === testing main()

#include <string.h>
#include "karu_hal.h"

const char main_hello[] =
"\n[RESET]\n";

//  unit tests

int main()
{
    int fail = 0;

    sio_puts(main_hello);

    if (fail) {
        sio_puts("[FAIL]\tSome tests failed.\n");
    } else {
        sio_puts("[PASS]\tAll tests ok.\n");
    }

    sio_putc('\n');
    sio_putc(4);  //  translated to EOF
    sio_putc(0);

    return 0;
}

