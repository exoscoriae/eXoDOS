#include "harness.h"
#define GCC_UNLIKELY(x) (x)
#define E_Exit(...) do{}while(0)
typedef double Real64;
#include <cmath>
FPU_rec fpu; Bit8u guestmem[1<<16];
#define LONGTYPE(a) a##ULL
#define BIAS80 16383
#define BIAS64 1023
static const double PI=3.14159265358979323846, L2E=1.4426950408889634074,
  L2T=3.3219280948873623479, LN2=0.69314718055994530942, LG2=0.30102999566398119521;
#include "orig_core.h"
int main(){
    FPU_FINIT(); TOP = FPU_GET_TOP();
    Bit64s v = 0x0DDF000000000000LL;
    memcpy(guestmem+0x100, &v, 8);
    FPU_PREP_PUSH(); FPU_FLD_I64(0x100, TOP);
    FPU_FBST(0x200);
    char bcd[24]; int n=0;
    for (int i=9;i>=0;i--){ Bit8u b=guestmem[0x200+i];
        if(i==9){ bcd[n++]=(char)('0'+(b&0xf)); } else { bcd[n++]=(char)('0'+((b>>4)&0xf)); bcd[n++]=(char)('0'+(b&0xf)); } }
    bcd[n]=0;
    bool ok = strcmp(bcd,"0999517642299539456")==0;
    printf("  original double core -> %s   %s\n", bcd, ok?"ok":"FAIL (expected)");
    return ok ? 1 : 0;   /* we EXPECT this to fail */
}
