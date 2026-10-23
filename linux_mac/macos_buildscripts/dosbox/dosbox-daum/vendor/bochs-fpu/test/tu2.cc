/* A second translation unit including fpu_instructions_softfloat.h.
 *
 * This exists because src/cpu/core_dynrec/dyn_fpu.h now includes the same
 * header that src/fpu/fpu.cpp does, so the build has two translation units
 * pulling it in.  Two things have to hold for that to be safe, and neither is
 * obvious from reading the header:
 *
 *   1. Nothing in it may have external linkage, or the two TUs collide at link
 *      time with a duplicate symbol.
 *   2. The entry points must survive as real functions whose address can be
 *      taken.  dyn_fpu.h does not call them -- it emits machine code that calls
 *      them, via gen_call_function_R((void*)&FPU_FADD_EA, ...).  A header that
 *      only worked when everything inlined would compile in fpu.cpp and fail
 *      here.
 *
 * Both are checked by simply building this file alongside test.cc and linking.
 * The array below is the list of entry points core_dynrec actually takes the
 * address of; if the header ever stops providing one of them, the link fails
 * with a name rather than the recompiler quietly calling something else.
 *
 * Build is the same command as test.cc -- just add test/tu2.cc.  See
 * ../README.md.
 */
#include "harness.h"
extern FPU_rec fpu;                 /* both defined in test.cc */
extern Bit8u guestmem[1<<16];
#include "fpu_instructions_softfloat.h"

void *dynrec_fpu_entry_points[] = {
    (void*)&FPU_FADD_EA,   (void*)&FPU_FMUL_EA,    (void*)&FPU_FDIV_EA,
    (void*)&FPU_FLD_F32_EA,(void*)&FPU_FLD_F64_EA,
    (void*)&FPU_FLD_I16_EA,(void*)&FPU_FLD_I32_EA,
    (void*)&FPU_FST_F32,   (void*)&FPU_FST_F64,    (void*)&FPU_FST_I32,
    (void*)&FPU_FBLD,      (void*)&FPU_FBST,       (void*)&FPU_FPATAN,
    (void*)&FPU_FPREM,     (void*)&FPU_FPREM1,     (void*)&FPU_FSCALE,
    (void*)&FPU_FXTRACT,   (void*)&FPU_FXAM,
    (void*)&FPU_FCOM,      (void*)&FPU_FUCOM,
    (void*)&FPU_FSAVE,     (void*)&FPU_FRSTOR,
    (void*)&FPU_FSTENV,    (void*)&FPU_FLDENV,
};

int dynrec_tu_entry_count(void) {
    return (int)(sizeof dynrec_fpu_entry_points / sizeof *dynrec_fpu_entry_points);
}
