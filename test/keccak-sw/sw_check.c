#include <stdint.h>
#include "sw_expected.h"
int sw_check(unsigned kind,const uint64_t *s,const uint64_t *out) {
    const uint64_t *expected[]={state0,state1,state2,state3};
    for(unsigned i=0;i<25;++i) if(s[i]!=expected[kind][i]) return 1;
    if(kind>=2) {
        const uint64_t *want=kind==2?out2:out3;
        unsigned n=16*(kind==2?21:17);
        for(unsigned i=0;i<n;++i) if(out[i]!=want[i]) return 1;
    }
    return 0;
}
