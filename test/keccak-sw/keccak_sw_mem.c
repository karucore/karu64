#include <stddef.h>
void *memset(void *p, int c, size_t n) {
    volatile unsigned char *q=p;
    for(size_t i=0;i<n;++i) q[i]=(unsigned char)c;
    return p;
}
void *memcpy(void *p, const void *s, size_t n) {
    volatile unsigned char *q=p; const unsigned char *r=s;
    for(size_t i=0;i<n;++i) q[i]=r[i];
    return p;
}
