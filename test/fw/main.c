//  main.c
//  2025-05-08  Markku-Juhani O. Saarinen <mjos@iki.fi>
//  === testing main()

#include <string.h>
#include "iutsys_hal.h"

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

    //  get input (test UART)
/*
#ifdef IUTSYS
    sio_puts("\nUART Test. Press x to exit.\n");
    int ch, gpio, old_gpio;

    ch = 0;
    old_gpio = -1;

    do {
        gpio = get_gpio_in();
        if (gpio != old_gpio) {
            sio_puts("GPIO 0x");
            sio_put_hex(gpio, 2);
            sio_putc('\n');
            old_gpio = gpio;
        }

        if (get_uart_rxok()) {
            ch = get_uart_rx();
            sio_puts("UART 0x");
            sio_put_hex(ch, 2);
            sio_putc(' ');
            sio_putc(ch);
            sio_putc('\n');
        }

    } while (ch != 'x');
#endif
*/
    sio_putc('\n');
    sio_putc(4);  //  translated to EOF
    sio_putc(0);

    return 0;
}

