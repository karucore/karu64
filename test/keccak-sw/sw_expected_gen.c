#include <stdint.h>
#include <stdio.h>
#include "keccak_sw_inline.h"
static void emit(const char *prefix,unsigned kind,const uint64_t *p,unsigned n) {
    printf("static const uint64_t %s%u[%u] = {\n",prefix,kind,n);
    for(unsigned i=0;i<n;++i) printf("0x%016llxUL,%s",(unsigned long long)p[i],i%4==3?"\n":" ");
    printf("\n};\n");
}
int main(void) {
    for(unsigned kind=0;kind<4;++kind) {
        unsigned words=(kind&1)?17:21;
        uint64_t s[25]={0},out[336]={0};
        for(unsigned block=0;block<16;++block) {
            for(unsigned i=0;i<words;++i) {
                if(kind<2) s[i]^=0x0101010101010101UL*(block*words+i);
                else out[block*words+i]=s[i];
            }
            KeccakF1600_StatePermute(s);
        }
        emit("state",kind,s,25);
        if(kind>=2) emit("out",kind,out,16*words);
    }
}
