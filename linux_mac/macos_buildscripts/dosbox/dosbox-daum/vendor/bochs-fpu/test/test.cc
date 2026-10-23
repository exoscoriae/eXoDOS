#include "harness.h"
FPU_rec fpu; Bit8u guestmem[1<<16];
#include "fpu_instructions_softfloat.h"
#include <cmath>

static int fails = 0;
static void ck(const char* n, bool ok, const char* got=""){
    printf("  %-44s %s %s\n", n, ok?"ok  ":"FAIL", got); if(!ok) fails++;
}

/* Read a register back as a double.  Only used where the expected value is
 * exactly representable in 53 bits, so the narrowing never decides a result. */
static double tod(floatx80 v){
    softfloat_status_t s; memset(&s,0,sizeof s);
    Bit64u r = extF80_to_f64(v,&s); double d; memcpy(&d,&r,8); return d;
}
/* Push through the real FLD path rather than SF_set, so the load is part of
 * what is under test. */
static void pushd(double d){
    Bit64u r; memcpy(&r,&d,8); memcpy(guestmem+0x400,&r,8);
    FPU_PREP_PUSH(); FPU_FLD_F64(0x400,TOP);
}
static bool nearly(double a,double b){ return fabs(a-b) < 1e-15*(fabs(b)+1); }
static floatx80 qnan(void){
    floatx80 q; q.signExp=0x7FFF; q.signif=BX_CONST64(0xC000000000000000); return q;
}
static floatx80 snan(void){
    floatx80 q; q.signExp=0x7FFF; q.signif=BX_CONST64(0x8000000000000001); return q;
}

int main(){
    FPU_FINIT(); TOP = FPU_GET_TOP();

    /* --- the OLE2DISP.DLL sequence: FILD qword -> FBSTP tbyte --- */
    Bit64s v = 0x0DDF000000000000LL;              /* 999517642299539456 */
    memcpy(guestmem+0x100, &v, 8);
    FPU_PREP_PUSH(); FPU_FLD_I64(0x100, TOP);
    FPU_FBST(0x200);
    char bcd[24]; int n=0;
    for (int i=9;i>=0;i--){ Bit8u b=guestmem[0x200+i];
        if(i==9){ bcd[n++]=(char)('0'+(b&0xf)); } else { bcd[n++]=(char)('0'+((b>>4)&0xf)); bcd[n++]=(char)('0'+(b&0xf)); } }
    bcd[n]=0;
    ck("FILD/FBSTP exact (OLE2DISP)", strcmp(bcd,"0999517642299539456")==0, bcd);
    ck("  last four digits are 9456", strcmp(bcd+15,"9456")==0, bcd+15);

    /* --- 80-bit round trip through memory --- */
    FPU_FINIT(); TOP=FPU_GET_TOP();
    FPU_FLDPI();
    FPU_FST_F80(0x300);
    floatx80 a = SF_get(TOP);
    FPU_FLD_F80(0x300);
    floatx80 b = SF_get(TOP);
    ck("FSTP/FLD tbyte round trip", a.signif==b.signif && a.signExp==b.signExp);

    /* --- constants match Bochs --- */
    FPU_FINIT(); TOP=FPU_GET_TOP(); FPU_FLDPI(); a=SF_get(TOP);
    ck("FLDPI bit-exact", a.signExp==0x4000 && a.signif==0xc90fdaa22168c235ULL);
    FPU_FINIT(); TOP=FPU_GET_TOP(); FPU_FLDLN2(); a=SF_get(TOP);
    ck("FLDLN2 bit-exact", a.signExp==0x3ffe && a.signif==0xb17217f7d1cf79acULL);

    /* --- 2 + 2, and 1/3 carrying more than double precision --- */
    FPU_FINIT(); TOP=FPU_GET_TOP();
    FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(2));
    FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(2));
    FPU_FADD(TOP, STV(1));
    { softfloat_status_t s=SF_status(); ck("2+2==4", extF80_to_i64(SF_get(TOP),0,false,&s)==4); }

    FPU_FINIT(); TOP=FPU_GET_TOP();
    FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(1));
    FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(3));
    FPU_FDIV(STV(1), TOP);
    a = SF_get(STV(1));
    /* 1/3 in 80-bit has significand 0xAAAA...AB; a double would end ...A800 */
    ck("1/3 keeps 64-bit significand", (a.signif & 0x7FF) != 0);

    /* --- sqrt and a transcendental actually run --- */
    FPU_FINIT(); TOP=FPU_GET_TOP();
    FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(144)); FPU_FSQRT();
    { softfloat_status_t s=SF_status(); ck("sqrt(144)==12", extF80_to_i64(SF_get(TOP),0,false,&s)==12); }

    FPU_FINIT(); TOP=FPU_GET_TOP();
    FPU_FLDZ(); FPU_FSIN();
    a=SF_get(TOP); ck("sin(0)==0", a.signif==0);
    FPU_FINIT(); TOP=FPU_GET_TOP();
    FPU_FLDZ(); FPU_FCOS();
    a=SF_get(TOP); ck("cos(0)==1", a.signExp==0x3fff && a.signif==0x8000000000000000ULL);

    /* --- FXAM classification --- */
    FPU_FINIT(); TOP=FPU_GET_TOP(); FPU_FLDZ(); FPU_FXAM();
    ck("FXAM(zero) sets C3, clears C2", (fpu.sw&0x4000) && !(fpu.sw&0x0400));

    /* --- FPREM vs FPREM1 ---
     * The two differ only in how the quotient is rounded before the
     * multiply-subtract, and 5 rem 3 is the smallest case that separates them:
     *   FPREM  truncates the quotient (1) -> 5 - 1*3 =  2
     *   FPREM1 rounds to nearest     (2) -> 5 - 2*3 = -1
     * C's fmod() is specified with truncation, so a core that aliases the two
     * returns -1 for fmod(5,3).  These four assertions are what stops that
     * being reintroduced.
     *
     * Naming the expected value for BOTH instructions matters: a test that
     * only pinned FPREM would still pass if FPREM1 were made to alias IT. */
    {
        softfloat_status_t s;
        Bit64s got;

        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(3));      /* ST1 <- 3 */
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(5));      /* ST0 <- 5 */
        FPU_FPREM();
        s=SF_status(); got = extF80_to_i64(SF_get(TOP), 3 /*chop*/, false, &s);
        ck("FPREM  5,3 == 2 (truncated quotient)", got==2);
        /* quotient 1 -> C1 set, C3 and C0 clear; C2 clear = reduction complete */
        ck("FPREM  quotient bits: C1 set, C2 clear",
           (fpu.sw&0x0200) && !(fpu.sw&0x0400) && !(fpu.sw&0x4000) && !(fpu.sw&0x0100));

        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(3));
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(5));
        FPU_FPREM1();
        s=SF_status(); got = extF80_to_i64(SF_get(TOP), 3, false, &s);
        ck("FPREM1 5,3 == -1 (nearest quotient)", got==-1);
        /* quotient 2 -> C3 set, C1 clear */
        ck("FPREM1 quotient bits: C3 set, C1 clear",
           (fpu.sw&0x4000) && !(fpu.sw&0x0200) && !(fpu.sw&0x0400));

        /* Incomplete reduction must SAY so.  A 2^80-scaled dividend needs more
         * than the 63 bits of exponent one execution can remove, so C2 comes
         * back set and the guest is expected to run the instruction again --
         * the behaviour DOSBox's old cores could not have, and hardcoded away. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(3));
        FPU_PREP_PUSH();
        { floatx80 big = i32_to_extF80(5); big.signExp += 80; SF_set(TOP, big); }
        FPU_FPREM();
        ck("FPREM sets C2 when reduction is incomplete", (fpu.sw&0x0400)!=0);
    }

    /* --- exception masks decide the RESULT, not just the flags ---
     *
     * SoftFloat consults the mask bits while rounding.  An unmasked overflow
     * takes the x87 wrap branch (`exp -= 0x6000`, the 24576 bias adjustment a
     * trap handler is meant to unpick); a masked one returns infinity.  DOS
     * boots with CW=0x37F -- all six masked -- so infinity is what a DOS
     * program expects, and declaring everything unmasked (the old
     * softfloat_exceptionMasks = 0) produced a wrapped finite number instead. */
    {
        /* 2^16000, twice: the product overflows the 15-bit exponent. */
        floatx80 big;
        big.signExp = 0x3FFF + 16000;
        big.signif  = 0x8000000000000000ULL;

        FPU_FINIT(); TOP=FPU_GET_TOP();               /* CW = 0x37F, all masked */
        FPU_PREP_PUSH(); SF_set(TOP, big);
        FPU_PREP_PUSH(); SF_set(TOP, big);
        FPU_FMUL(TOP, STV(1));
        a = SF_get(TOP);
        ck("masked overflow -> +INF",
           a.signExp==0x7FFF && a.signif==0x8000000000000000ULL);
        ck("masked overflow: OE set, ES clear",
           (fpu.sw&0x0008) && !(fpu.sw&0x0080));
        /* FXAM's encoding for infinity, pinned here because the in-emulator
         * test in vendor/fputest.asm reads it out of the status word and this
         * is the only place that claim can be checked before it is written in
         * assembly: C3=0, C2=1, C0=1, i.e. sw & 0x4500 == 0x0500. */
        FPU_FXAM();
        ck("FXAM(+INF): sw & 0x4500 == 0x0500", (fpu.sw & 0x4500) == 0x0500);

        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_SetCW(0x37F & ~0x0008);                   /* unmask overflow only */
        FPU_PREP_PUSH(); SF_set(TOP, big);
        FPU_PREP_PUSH(); SF_set(TOP, big);
        FPU_FMUL(TOP, STV(1));
        a = SF_get(TOP);
        ck("unmasked overflow -> wrapped, not INF", a.signExp!=0x7FFF);
        ck("unmasked overflow: ES and B set", (fpu.sw&0x0080) && (fpu.sw&0x8000));

        /* Divide by zero, both ways.  The result is the same either way; what
         * changes is whether the guest is told anybody should care. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(0));
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(1));
        FPU_FDIV(TOP, STV(1));
        a = SF_get(TOP);
        ck("masked 1/0 -> +INF", a.signExp==0x7FFF && a.signif==0x8000000000000000ULL);
        ck("masked 1/0: ZE set, ES clear", (fpu.sw&0x0004) && !(fpu.sw&0x0080));

        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_SetCW(0x37F & ~0x0004);                   /* unmask divide-by-zero */
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(0));
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(1));
        FPU_FDIV(TOP, STV(1));
        ck("unmasked 1/0: ES set", (fpu.sw&0x0080)!=0);

        /* FCLEX must clear the summary as well as the flags, or ES latches on
         * for the rest of the program's life. */
        FPU_FCLEX();
        ck("FCLEX clears ES, B and the flags", (fpu.sw & 0x80ff)==0);

        /* And a masked exception must never set ES, however many of them
         * accumulate -- this is the bit that decides whether a polling loop
         * thinks something went wrong. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(3));   /* ST1 <- 3 */
        FPU_PREP_PUSH(); SF_set(TOP, i32_to_extF80(1));   /* ST0 <- 1 */
        FPU_FDIV(TOP, STV(1));                            /* 1/3: inexact */
        ck("masked inexact: PE set, ES still clear",
           (fpu.sw&0x0020) && !(fpu.sw&0x0080));
    }

    /* ================================================================== *
     * The entry points that had no coverage at all.
     * ================================================================== */
    {
        char buf[96];
        double got;

        /* --- FPATAN: ST(1) <- atan(ST(1)/ST(0)), then pop ---------------
         * Both directions, because a single case would still pass with the
         * operands exchanged if the two happened to be symmetric.  atan(2)
         * and atan(1/2) are each other's complement, so a swap turns one
         * expected value into the other and both assertions fire. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(2.0);                       /* ST(1) */
        pushd(1.0);                       /* ST(0) -> atan(2/1) */
        FPU_FPATAN();
        got = tod(SF_get(TOP));
        snprintf(buf,sizeof buf,"got %.15f", got);
        ck("FPATAN(ST1=2,ST0=1) == atan(2)", nearly(got, atan(2.0)), buf);

        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(1.0);                       /* ST(1) */
        pushd(2.0);                       /* ST(0) -> atan(1/2) */
        FPU_FPATAN();
        got = tod(SF_get(TOP));
        snprintf(buf,sizeof buf,"got %.15f", got);
        ck("FPATAN(ST1=1,ST0=2) == atan(1/2)", nearly(got, atan(0.5)), buf);

        /* Control: FYL2X takes its operands the OTHER way round from FPATAN
         * in Bochs' API, and always did.  If a future edit "makes them
         * consistent", this fails and FPATAN's two do not. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(3.0);                       /* y */
        pushd(8.0);                       /* x -> 3*log2(8) */
        FPU_FYL2X();
        got = tod(SF_get(TOP));
        snprintf(buf,sizeof buf,"got %.15f", got);
        ck("FYL2X(y=3,x=8) == 9 [operand-order control]", nearly(got,9.0), buf);

        /* --- FCOM signals on a QNaN, FUCOM does not --------------------
         * The comparison RESULT is identical for both (unordered, 0x4500);
         * only IE separates them.  Asserting the result as well as the flag
         * keeps a "fix" that makes FCOM return ordered from passing. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(1.0); FPU_PREP_PUSH(); SF_set(TOP, qnan());
        FPU_FCOM(TOP, STV(1));
        snprintf(buf,sizeof buf,"sw=0x%04x", fpu.sw);
        ck("FCOM vs QNaN: unordered AND IE set",
           (fpu.sw & 0x4500)==0x4500 && (fpu.sw & 0x0001), buf);

        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(1.0); FPU_PREP_PUSH(); SF_set(TOP, qnan());
        FPU_FUCOM(TOP, STV(1));
        snprintf(buf,sizeof buf,"sw=0x%04x", fpu.sw);
        ck("FUCOM vs QNaN: unordered, IE clear",
           (fpu.sw & 0x4500)==0x4500 && !(fpu.sw & 0x0001), buf);

        /* An SNaN signals for both -- so aliasing FCOM to FUCOM cannot be
         * hidden by only ever testing signalling NaNs. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(1.0); FPU_PREP_PUSH(); SF_set(TOP, snan());
        FPU_FUCOM(TOP, STV(1));
        snprintf(buf,sizeof buf,"sw=0x%04x", fpu.sw);
        ck("FUCOM vs SNaN: IE set", (fpu.sw & 0x0001)!=0, buf);

        /* Ordinary ordered compares must not signal anything at all. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(3.0); pushd(1.0);
        FPU_FCOM(TOP, STV(1));
        snprintf(buf,sizeof buf,"sw=0x%04x", fpu.sw);
        ck("FCOM 1 vs 3: C0 set, no exception",
           (fpu.sw & 0x4500)==0x0100 && (fpu.sw & 0x00bf)==0, buf);

        /* Comparing against an empty register is a stack fault: IE and SF. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(1.0);
        FPU_FCOM(TOP, STV(1));            /* ST(1) was never pushed */
        snprintf(buf,sizeof buf,"sw=0x%04x", fpu.sw);
        ck("FCOM vs empty: unordered, IE+SF set",
           (fpu.sw & 0x4500)==0x4500 && (fpu.sw & 0x0041)==0x0041, buf);

        /* --- FSCALE: ST(0) <- ST(0) * 2^trunc(ST(1)) ------------------- */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(3.0); pushd(5.0);
        FPU_FSCALE();
        got = tod(SF_get(TOP));
        snprintf(buf,sizeof buf,"got %.15f", got);
        ck("FSCALE(5, 3) == 40", nearly(got,40.0), buf);

        /* The scale is TRUNCATED toward zero, not rounded: -2.7 -> -2, so
         * 1 * 2^-2 = 0.25.  Rounding to nearest would give 0.125. */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(-2.7); pushd(1.0);
        FPU_FSCALE();
        got = tod(SF_get(TOP));
        snprintf(buf,sizeof buf,"got %.15f (0.125 would mean it rounded)", got);
        ck("FSCALE(1, -2.7) truncates toward zero == 0.25", nearly(got,0.25), buf);

        /* --- FXTRACT: ST(0) <- exponent, then push the significand ----- */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        pushd(40.0);                      /* 40 = 1.25 * 2^5 */
        FPU_FXTRACT();
        {
            double sig = tod(SF_get(TOP));        /* pushed last */
            double ex  = tod(SF_get(STV(1)));
            snprintf(buf,sizeof buf,"exp=%.15f sig=%.15f", ex, sig);
            ck("FXTRACT(40): ST0=1.25, ST1=5 (not reversed)",
               nearly(sig,1.25) && nearly(ex,5.0), buf);
        }

        /* --- FBLD / FBST: packed BCD, including the sign byte ---------- */
        FPU_FINIT(); TOP=FPU_GET_TOP();
        memset(guestmem+0x500,0,10);
        guestmem[0x500]=0x90; guestmem[0x501]=0x78; guestmem[0x502]=0x56;
        guestmem[0x503]=0x34; guestmem[0x504]=0x12; guestmem[0x509]=0x80;
        FPU_PREP_PUSH(); FPU_FBLD(0x500, TOP);
        got = tod(SF_get(TOP));
        snprintf(buf,sizeof buf,"got %.1f", got);
        ck("FBLD(-1234567890): digits and sign", nearly(got,-1234567890.0), buf);

        FPU_FBST(0x600);
        ck("FBST round-trips the same 10 bytes",
           memcmp(guestmem+0x500, guestmem+0x600, 10)==0);
    }

    printf("\n%s (%d failure%s)\n", fails?"FAILURES":"all passed", fails, fails==1?"":"s");
    return fails!=0;
}
