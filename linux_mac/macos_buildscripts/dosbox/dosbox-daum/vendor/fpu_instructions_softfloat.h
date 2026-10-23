/* fpu_instructions_softfloat.h -- DOSBox Daum FPU core on Berkeley SoftFloat-3e.
 *
 * WHY THIS EXISTS
 * ---------------
 * Daum ships two FPU cores and picks between them in fpu.cpp:
 *
 *   C_FPU_X86  -> fpu_instructions_x86.h    real x87, via MSVC __asm blocks
 *   else       -> fpu_instructions.h        portable C, computing in `double`
 *
 * configure.ac defines C_FPU_X86 only for x86/x86_64, so a universal macOS
 * build gets 80-bit intermediates on the Intel slice and 53-bit on the Apple
 * Silicon slice.  That is not a rounding curiosity.  x87 has a 64-bit
 * significand; `double` has 53.  OLE2DISP.DLL 2.3.3027.1 -- the OLE layer of
 * Windows 3.1x -- deliberately tests for exactly this: it does FILD of a 64-bit
 * integer, FBSTP to packed BCD, and compares the last four digits.  On the
 * double core they come back wrong, the DLL pops an extra stack entry, and
 * DOSBox aborts on the resulting FPU stack underflow.  Windows 3.1 OLE
 * applications therefore run on Intel and die on Apple Silicon.
 *
 * `long double` is not a way out.  DOSBox-X solves this with
 * fpu_instructions_longdouble.h, but that reinterprets an 80-bit memory image
 * through a `long double` union -- correct only where long double IS the x87
 * format.  On Apple Silicon `long double` is a synonym for `double`, so that
 * file would not merely lose precision there, it would read garbage.
 *
 * So the precision is emulated in software, identically on every target.  Both
 * slices then compute bit-for-bit alike, and save states become portable.
 *
 * STORAGE
 * -------
 * Values live in fpu.p_regs[], which already exists and is already the 80-bit
 * packed x87 layout: the MSVC core writes it with `fstp TBYTE PTR ...m1`, so
 * m1 = significand[31:0], m2 = significand[63:32], m3 = sign+exponent.  That is
 * a direct lossless mapping onto SoftFloat's extFloat80_t {signif, signExp}.
 *
 * Two things follow.  Nothing outside src/fpu/ reads fpu.regs or fpu.p_regs, so
 * changing representation touches nothing else; and because the struct is
 * unchanged, registerPOD(fpu) still serialises the same bytes -- save states
 * stay format-compatible with what the Intel slice writes today, and now
 * transfer between architectures.
 *
 * ROUNDING happens to map 1:1.  DOSBox's FPU_Round {Nearest,Down,Up,Chop} =
 * {0,1,2,3} is exactly softfloat's {near_even,min,max,minMag}.
 *
 * PRECISION CONTROL is honoured, which the stock cores do not do: FPU_SetCW
 * extracts only the rounding field, so a program asking for 24- or 53-bit
 * precision silently gets full precision.  SoftFloat takes it directly.
 *
 * Berkeley SoftFloat-3e is BSD-3-Clause; the x87 transcendentals are LGPL from
 * Bochs.  Both are GPLv2-compatible.  See vendor/bochs-fpu/.
 */

#include <cmath>
#include <cstring>

#include "softfloat3e/include/softfloat.h"
#include "dbfpu.h"

/* Bochs' standalone x87 helpers.  None of these reference Bochs' CPU class;
 * they are plain floatx80 -> floatx80 functions. */
extern floatx80 f2xm1(floatx80 a, softfloat_status_t &status);
extern floatx80 fyl2x(floatx80 a, floatx80 b, softfloat_status_t &status);
extern floatx80 fyl2xp1(floatx80 a, floatx80 b, softfloat_status_t &status);
extern floatx80 fpatan(floatx80 a, floatx80 b, softfloat_status_t &status);
extern int      fsincos(floatx80 a, floatx80 *sin_a, floatx80 *cos_a, softfloat_status_t &status);
extern int      fsin(floatx80 &a, softfloat_status_t &status);
extern int      fcos(floatx80 &a, softfloat_status_t &status);
extern int      ftan(floatx80 &a, softfloat_status_t &status);

/* ------------------------------------------------------------------ *
 * register access
 * ------------------------------------------------------------------ */

static INLINE floatx80 SF_get(Bitu reg) {
	floatx80 r;
	r.signif  =  (Bit64u)fpu.p_regs[reg].m1 | ((Bit64u)fpu.p_regs[reg].m2 << 32);
	r.signExp = fpu.p_regs[reg].m3;
	return r;
}

static INLINE void SF_set(Bitu reg, floatx80 v) {
	fpu.p_regs[reg].m1 = (Bit32u)(v.signif & 0xFFFFFFFFu);
	fpu.p_regs[reg].m2 = (Bit32u)(v.signif >> 32);
	fpu.p_regs[reg].m3 = v.signExp;
}

/* Build the softfloat status from the guest control word every operation.
 * The guest can change CW at any time and the cost is a few stores. */
static INLINE softfloat_status_t SF_status(void) {
	softfloat_status_t s;
	s.softfloat_roundingMode = (uint8_t)fpu.round;   /* 1:1, see header note */
	s.softfloat_exceptionFlags = 0;
	/* The masks map 1:1 as well: CW bits 0..5 are IM DM ZM OM UM PM, and
	 * softfloat_flag_{invalid,denormal,divbyzero,overflow,underflow,inexact}
	 * are 0x01..0x20 in that same order.  Bochs makes the same assignment.
	 *
	 * This is NOT bookkeeping -- it changes results.  SoftFloat consults the
	 * masks when it rounds: an UNMASKED overflow takes the x87 wrap branch in
	 * s_roundPackToExtF80.cc (`exp -= 0x6000`, the 24576 bias adjustment a
	 * trap handler is meant to unpick), while a MASKED one returns infinity.
	 * Leaving this at 0 declared everything unmasked, so every overflow
	 * produced a wrapped finite number where DOS -- which boots with CW=0x37F,
	 * all six masked -- expects +INF.  Silently wrong arithmetic, in the one
	 * place a program is least likely to check. */
	s.softfloat_exceptionMasks = (int)(fpu.cw & 0x3f);
	s.softfloat_suppressException = 0;
	s.softfloat_denormals_are_zeros = false;
	s.softfloat_flush_underflow_to_zero = false;
	/* x87 precision control, CW bits 9:8 -- 00 = 24-bit, 10 = 53-bit,
	 * 11 = 64-bit significand.  01 is reserved; treat as extended. */
	switch ((fpu.cw >> 8) & 3) {
		case 0:  s.extF80_roundingPrecision = 32; break;
		case 2:  s.extF80_roundingPrecision = 64; break;
		default: s.extF80_roundingPrecision = 80; break;
	}
	return s;
}

/* Status word update.
 *
 * The six exception bits sit in the same order as the CW masks and as
 * softfloat's flags, so this is a straight OR -- they are sticky and set
 * whether or not the exception is masked, exactly as the hardware does.
 *
 * ES (0x80) and B (0x8000) are the part DOSBox's portable core never had.  ES
 * is the exception summary: set when an exception occurs that the guest has
 * NOT masked, and sticky until FCLEX or FINIT.  B mirrors it on a 387 and
 * later.  Daum's x86 core got both for free -- it ran the operation on the
 * real host FPU and merged the hardware's status word (`fpu.sw = (new_sw &
 * 0xffbf) | (fpu.sw & 0x80ff)`) -- so on Intel this worked and on Apple
 * Silicon it did not.  Reproducing it here is what makes the two agree.
 *
 * Not delivered: the trap itself.  Real hardware asserts FERR#, the PC routes
 * it to IRQ13 and INT 75h, and a handler runs.  DOSBox has no #MF and no IRQ13
 * FPU path -- there is nothing to raise -- so the result is written and
 * execution continues.  That is a deliberate stopping point, not an oversight:
 * suppressing the write, which is what the hardware does, would leave the
 * guest in a state it could only get out of via the handler we cannot call.
 * Code that POLLS -- `fdiv` / `fnstsw ax` / `test ah,0x80` -- now reads the
 * truth, which is the common DOS idiom; code that installs an INT 75h handler
 * still will not see it fire. */
static INLINE void SF_flags(const softfloat_status_t &s) {
	Bitu raised = 0;
	if (s.softfloat_exceptionFlags & softfloat_flag_invalid)   raised |= 0x0001;
	if (s.softfloat_exceptionFlags & softfloat_flag_denormal)  raised |= 0x0002;
	if (s.softfloat_exceptionFlags & softfloat_flag_divbyzero) raised |= 0x0004;
	if (s.softfloat_exceptionFlags & softfloat_flag_overflow)  raised |= 0x0008;
	if (s.softfloat_exceptionFlags & softfloat_flag_underflow) raised |= 0x0010;
	if (s.softfloat_exceptionFlags & softfloat_flag_inexact)   raised |= 0x0020;

	fpu.sw |= (Bit16u)raised;
	if (raised & ~(Bitu)(fpu.cw & 0x3f)) fpu.sw |= 0x0080 | 0x8000;   /* ES, B */

	/* Every arithmetic op funnels its status through here, so this single hook
	 * covers all of them -- and both CPU cores, since both include this file. */
	if (dbfpu().on) {
		if (raised & 0x0001) dbfpu_anomaly(DBA_IE);
		if (raised & 0x0002) dbfpu_anomaly(DBA_DE);
		if (raised & 0x0004) dbfpu_anomaly(DBA_ZE);
		if (raised & 0x0008) dbfpu_anomaly(DBA_OE);
		if (raised & 0x0010) dbfpu_anomaly(DBA_UE);
		if (raised & 0x0020) dbfpu_anomaly(DBA_PE);
		if (raised & ~(Bitu)(fpu.cw & 0x3f)) dbfpu_anomaly(DBA_ES);
	}
}

#define SF_BEGIN softfloat_status_t st = SF_status()
#define SF_END   SF_flags(st)

static INLINE floatx80 SF_from_i64(Bit64s v) { return i64_to_extF80(v); }

static INLINE Bit64s SF_to_i64(floatx80 a, softfloat_status_t &st) {
	return extF80_to_i64(a, (uint8_t)fpu.round, false, &st);
}

/* ------------------------------------------------------------------ *
 * stack management
 * ------------------------------------------------------------------ */

/* Stack over/underflow.
 *
 * Both stock cores hard-abort here -- fpu_instructions.h:59 is
 * `E_Exit("FPU stack underflow")` -- and this core, replacing them, dropped the
 * check entirely and did not put anything in its place.  So the single most
 * diagnostic FPU fault in DOSBox's history became completely unobservable: no
 * abort, no status bit, no counter.
 *
 * That matters more than it looks.  The OLE2DISP.DLL failure this whole core
 * exists to fix presents exactly as "the DLL pops an extra stack entry" -- so
 * the symptom we most want to detect was the one thing nothing recorded.
 *
 * The hardware behaviour is to set IE and SF, with C1 distinguishing the two
 * (1 = overflow, 0 = underflow), and -- masked, which DOS always is -- to
 * deliver the indefinite QNaN and continue.  Flags and counters only here: the
 * VALUE behaviour is left exactly as it was, because changing what a
 * misbehaving guest receives is a much larger claim than making the event
 * visible, and visibility is what was missing. */
static INLINE void FPU_StackFault(bool overflow) {
	fpu.sw |= 0x0001 | 0x0040;                 /* IE + SF */
	FPU_SET_C1(overflow ? 1 : 0);
	if (!(fpu.cw & 0x0001)) fpu.sw |= 0x0080 | 0x8000;   /* ES, B if unmasked */
	DBFPU_ANOM(DBA_SF); DBFPU_ANOM(DBA_IE);
}

static void FPU_PUSH(floatx80 in){
	if (GCC_UNLIKELY(fpu.tags[(TOP - 1) & 7] != TAG_Empty)) FPU_StackFault(true);
	TOP = (TOP - 1) & 7;
	fpu.tags[TOP] = TAG_Valid;
	SF_set(TOP, in);
}

static void FPU_PREP_PUSH(void){
	if (GCC_UNLIKELY(fpu.tags[(TOP - 1) & 7] != TAG_Empty)) FPU_StackFault(true);
	TOP = (TOP - 1) & 7;
	fpu.tags[TOP] = TAG_Valid;
}

static void FPU_FPOP(void){
	if (GCC_UNLIKELY(fpu.tags[TOP] == TAG_Empty)) FPU_StackFault(false);
	fpu.tags[TOP] = TAG_Empty;
	TOP = ((TOP + 1) & 7);
}

static void FPU_FINIT(void) {
	DBFPU_HIT(DBF_FINIT);
	FPU_SetCW(0x37F);
	fpu.sw = 0;
	TOP = FPU_GET_TOP();
	for (Bitu i = 0; i < 8; i++) fpu.tags[i] = TAG_Empty;
	fpu.tags[8] = TAG_Valid;
}

static void FPU_FCLEX(void){ 	DBFPU_HIT(DBF_FCLEX);
fpu.sw &= 0x7f00; }
static void FPU_FNOP(void){ return; }

/* ------------------------------------------------------------------ *
 * loads
 * ------------------------------------------------------------------ */

static floatx80 FPU_FLD80(PhysPt addr) {
	floatx80 r;
	r.signif  =  (Bit64u)mem_readd(addr) | ((Bit64u)mem_readd(addr+4) << 32);
	r.signExp = mem_readw(addr+8);
	return r;
}

static void FPU_ST80(PhysPt addr,Bitu reg) {
	floatx80 v = SF_get(reg);
	mem_writed(addr,   (Bit32u)(v.signif & 0xFFFFFFFFu));
	mem_writed(addr+4, (Bit32u)(v.signif >> 32));
	mem_writew(addr+8, v.signExp);
}

static void FPU_FLD_F32(PhysPt addr,Bitu store_to) {
	SF_BEGIN;
	SF_set(store_to, f32_to_extF80(mem_readd(addr), &st));
	SF_END;
}

static void FPU_FLD_F64(PhysPt addr,Bitu store_to) {
	SF_BEGIN;
	Bit64u raw = (Bit64u)mem_readd(addr) | ((Bit64u)mem_readd(addr+4) << 32);
	SF_set(store_to, f64_to_extF80(raw, &st));
	SF_END;
}

static void FPU_FLD_F80(PhysPt addr) { SF_set(TOP, FPU_FLD80(addr)); }

static void FPU_FLD_I16(PhysPt addr,Bitu store_to) {
	SF_set(store_to, i32_to_extF80((Bit32s)(Bit16s)mem_readw(addr)));
}

static void FPU_FLD_I32(PhysPt addr,Bitu store_to) {
	SF_set(store_to, i32_to_extF80((Bit32s)mem_readd(addr)));
}

static void FPU_FLD_I64(PhysPt addr,Bitu store_to) {
	DBFPU_HIT(DBF_FLD_I64);
	Bit64s v = (Bit64s)((Bit64u)mem_readd(addr) | ((Bit64u)mem_readd(addr+4) << 32));
	SF_set(store_to, SF_from_i64(v));   /* exact: 64-bit significand */
}

static void FPU_FBLD(PhysPt addr,Bitu store_to) {
	DBFPU_HIT(DBF_FBLD);
	/* Packed BCD is at most 18 digits, which fits int64 exactly, so this is
	 * integer arithmetic throughout -- no float rounding anywhere. */
	Bit64s val = 0, base = 1;
	for (Bitu i = 0; i < 9; i++) {
		Bitu in = mem_readb(addr + i);
		val += (Bit64s)(in & 0xf) * base;   base *= 10;
		val += (Bit64s)((in >> 4) & 0xf) * base; base *= 10;
	}
	Bitu in = mem_readb(addr + 9);
	val += (Bit64s)(in & 0xf) * base;
	if (in & 0x80) val = -val;
	SF_set(store_to, SF_from_i64(val));
}

static INLINE void FPU_FLD_F32_EA(PhysPt addr) { FPU_FLD_F32(addr,8); }
static INLINE void FPU_FLD_F64_EA(PhysPt addr) { FPU_FLD_F64(addr,8); }
static INLINE void FPU_FLD_I32_EA(PhysPt addr) { FPU_FLD_I32(addr,8); }
static INLINE void FPU_FLD_I16_EA(PhysPt addr) { FPU_FLD_I16(addr,8); }

/* ------------------------------------------------------------------ *
 * stores
 * ------------------------------------------------------------------ */

static void FPU_FST_F32(PhysPt addr) {
	SF_BEGIN; mem_writed(addr, extF80_to_f32(SF_get(TOP), &st)); SF_END;
}

static void FPU_FST_F64(PhysPt addr) {
	SF_BEGIN;
	Bit64u raw = extF80_to_f64(SF_get(TOP), &st);
	mem_writed(addr,   (Bit32u)(raw & 0xFFFFFFFFu));
	mem_writed(addr+4, (Bit32u)(raw >> 32));
	SF_END;
}

static void FPU_FST_F80(PhysPt addr) { FPU_ST80(addr,TOP); }

static void FPU_FST_I16(PhysPt addr) {
	SF_BEGIN; mem_writew(addr,(Bit16u)(Bit16s)SF_to_i64(SF_get(TOP),st)); SF_END;
}

static void FPU_FST_I32(PhysPt addr) {
	SF_BEGIN; mem_writed(addr,(Bit32u)(Bit32s)SF_to_i64(SF_get(TOP),st)); SF_END;
}

static void FPU_FST_I64(PhysPt addr) {
	DBFPU_HIT(DBF_FST_I64);
	SF_BEGIN;
	Bit64s v = SF_to_i64(SF_get(TOP),st);
	mem_writed(addr,   (Bit32u)((Bit64u)v & 0xFFFFFFFFu));
	mem_writed(addr+4, (Bit32u)((Bit64u)v >> 32));
	SF_END;
}

static void FPU_FBST(PhysPt addr) {
	DBFPU_HIT(DBF_FBST);
	/* This is the OLE2DISP.DLL case.  The stock core extracts digits with
	 * repeated `double` division by ten; the intermediate quotients need 57
	 * bits and a double has 53, so the low digits come out wrong.  18 digits
	 * fit int64 exactly, so do it in integers and the question disappears. */
	SF_BEGIN;
	Bit64s v = SF_to_i64(SF_get(TOP), st);
	bool sign = false;
	if (v < 0) { sign = true; v = -v; }
	for (Bitu i = 0; i < 9; i++) {
		Bitu lo = (Bitu)(v % 10); v /= 10;
		Bitu hi = (Bitu)(v % 10); v /= 10;
		mem_writeb(addr+i, (Bit8u)(lo | (hi << 4)));
	}
	Bitu p = (Bitu)(v % 10);
	if (sign) p |= 0x80;
	mem_writeb(addr+9, (Bit8u)p);
	SF_END;
}

/* ------------------------------------------------------------------ *
 * arithmetic
 * ------------------------------------------------------------------ */

static void FPU_FADD(Bitu op1, Bitu op2){
	DBFPU_HIT(DBF_FADD);
	SF_BEGIN; SF_set(op1, extF80_add(SF_get(op1), SF_get(op2), &st)); SF_END;
}
static void FPU_FSUB(Bitu st_, Bitu other){
	DBFPU_HIT(DBF_FSUB);
	SF_BEGIN; SF_set(st_, extF80_sub(SF_get(st_), SF_get(other), &st)); SF_END;
}
static void FPU_FSUBR(Bitu st_, Bitu other){
	SF_BEGIN; SF_set(st_, extF80_sub(SF_get(other), SF_get(st_), &st)); SF_END;
}
static void FPU_FMUL(Bitu st_, Bitu other){
	DBFPU_HIT(DBF_FMUL);
	SF_BEGIN; SF_set(st_, extF80_mul(SF_get(st_), SF_get(other), &st)); SF_END;
}
static void FPU_FDIV(Bitu st_, Bitu other){
	DBFPU_HIT(DBF_FDIV);
	SF_BEGIN; SF_set(st_, extF80_div(SF_get(st_), SF_get(other), &st)); SF_END;
}
static void FPU_FDIVR(Bitu st_, Bitu other){
	SF_BEGIN; SF_set(st_, extF80_div(SF_get(other), SF_get(st_), &st)); SF_END;
}
static void FPU_FSQRT(void){
	DBFPU_HIT(DBF_FSQRT);
	SF_BEGIN; SF_set(TOP, extF80_sqrt(SF_get(TOP), &st)); SF_END;
}

static void FPU_FCHS(void){
	floatx80 v = SF_get(TOP); v.signExp ^= 0x8000; SF_set(TOP, v);
}
static void FPU_FABS(void){
	floatx80 v = SF_get(TOP); v.signExp &= 0x7fff; SF_set(TOP, v);
}

static void FPU_FRNDINT(void){
	SF_BEGIN;
	SF_set(TOP, extF80_roundToInt(SF_get(TOP), (uint8_t)fpu.round, true, &st));
	SF_END;
}

/* FPREM and FPREM1 differ in exactly one thing: how the quotient is rounded
 * before the multiply-subtract.  FPREM truncates toward zero, FPREM1 rounds to
 * nearest even.  That sounds like a rounding nicety and is not -- the results
 * differ in sign and magnitude whenever the true quotient's fraction exceeds
 * a half:
 *
 *     FPREM (5, 3)   ->  5 - 1*3  =  2      truncated quotient 1
 *     FPREM1(5, 3)   ->  5 - 2*3  = -1      nearest quotient 2
 *
 * The C runtime's fmod() is specified with truncation, and Watcom/Borland
 * implement it as a FPREM loop, so aliasing the two -- which this file did --
 * makes fmod(5,3) return -1.  Wrong answers, no diagnostic.
 *
 * C2 is now honest as well.  Bochs' kernel reduces by at most 63 bits of
 * exponent per execution and reports whether it finished, exactly as the
 * hardware does; guest code loops on C2 until it clears.  DOSBox's old cores
 * always cleared C2, which was truthful for them -- computing in `double` they
 * always did finish -- but means a partial result would now be claimed
 * complete if the flag were left hardcoded. */
extern int floatx80_remainder(floatx80 a, floatx80 b, floatx80 &r,
                              uint64_t &q, softfloat_status_t *status);
extern int floatx80_ieee754_remainder(floatx80 a, floatx80 b, floatx80 &r,
                                      uint64_t &q, softfloat_status_t *status);

static void FPU_FPREM_kernel(bool ieee){
	SF_BEGIN;
	floatx80 r;
	uint64_t q = 0;
	int flags = ieee
		? floatx80_ieee754_remainder(SF_get(TOP), SF_get(STV(1)), r, q, &st)
		: floatx80_remainder(SF_get(TOP), SF_get(STV(1)), r, q, &st);
	SF_END;
	SF_set(TOP, r);
	/* Negative means NaN or an unsupported encoding: the result stands but the
	 * condition codes are left alone, which is what the hardware does. */
	if (flags < 0) return;
	if (flags) {
		FPU_SET_C2(1);           /* incomplete -- the guest must execute again */
	} else {
		FPU_SET_C2(0);
		FPU_SET_C0((Bitu)(q & 4));
		FPU_SET_C3((Bitu)(q & 2));
		FPU_SET_C1((Bitu)(q & 1));
	}
}

static void FPU_FPREM(void) { 	DBFPU_HIT(DBF_FPREM);
FPU_FPREM_kernel(false); }
static void FPU_FPREM1(void){ 	DBFPU_HIT(DBF_FPREM1);
FPU_FPREM_kernel(true);  }

static void FPU_FSCALE(void){
	DBFPU_HIT(DBF_FSCALE);
	SF_BEGIN;
	SF_set(TOP, extF80_scale(SF_get(TOP), SF_get(STV(1)), &st));
	SF_END;
}

static void FPU_FXTRACT(void) {
	DBFPU_HIT(DBF_FXTRACT);
	SF_BEGIN;
	floatx80 sig = SF_get(TOP);
	floatx80 exp = extF80_extract(&sig, &st);   /* leaves significand in sig */
	SF_END;
	SF_set(TOP, exp);
	FPU_PUSH(sig);
}

/* ------------------------------------------------------------------ *
 * transcendentals -- Bochs, on 128-bit intermediates
 * ------------------------------------------------------------------ */

static void FPU_FSIN(void){
	DBFPU_HIT(DBF_FSIN);
	SF_BEGIN; floatx80 a = SF_get(TOP);
	if (fsin(a, st) == 0) { SF_set(TOP, a); FPU_SET_C2(0); } else FPU_SET_C2(1);
	SF_END;
}
static void FPU_FCOS(void){
	DBFPU_HIT(DBF_FCOS);
	SF_BEGIN; floatx80 a = SF_get(TOP);
	if (fcos(a, st) == 0) { SF_set(TOP, a); FPU_SET_C2(0); } else FPU_SET_C2(1);
	SF_END;
}
static void FPU_FSINCOS(void){
	DBFPU_HIT(DBF_FSINCOS);
	SF_BEGIN; floatx80 s_, c_;
	if (fsincos(SF_get(TOP), &s_, &c_, st) == 0) {
		SF_set(TOP, s_); FPU_PUSH(c_); FPU_SET_C2(0);
	} else FPU_SET_C2(1);
	SF_END;
}
static void FPU_FPTAN(void){
	DBFPU_HIT(DBF_FPTAN);
	SF_BEGIN; floatx80 a = SF_get(TOP);
	if (ftan(a, st) == 0) {
		SF_set(TOP, a);
		FPU_PUSH(i32_to_extF80(1));
		FPU_SET_C2(0);
	} else FPU_SET_C2(1);
	SF_END;
}
/* FPATAN: ST(1) <- atan(ST(1) / ST(0)), then pop.
 *
 * Bochs' kernel takes the DENOMINATOR first: fpu_trans.cc calls
 * fpatan(BX_READ_FPU_REG(0), BX_READ_FPU_REG(1)) = fpatan(ST0, ST1), and
 * fpatan.cc confirms it -- when `b` is infinite and `a` finite it returns
 * +-PI/2, which is atan(b/a), so `a` is ST(0).  Passing them the other way
 * round computes atan(ST0/ST1), the complementary angle, for every input.
 *
 * FYL2X and FYL2XP1 below already use the (TOP, STV(1)) order; the asymmetry
 * was the whole bug.  Pinned by "FPATAN(ST1=2,ST0=1) == atan(2)" in
 * vendor/bochs-fpu/test/test.cc, which fails if these two are exchanged. */
static void FPU_FPATAN(void){
	DBFPU_HIT(DBF_FPATAN);
	SF_BEGIN;
	SF_set(STV(1), fpatan(SF_get(TOP), SF_get(STV(1)), st));
	SF_END;
	FPU_FPOP();
}
static void FPU_F2XM1(void){
	DBFPU_HIT(DBF_F2XM1);
	SF_BEGIN; SF_set(TOP, f2xm1(SF_get(TOP), st)); SF_END;
}
static void FPU_FYL2X(void){
	DBFPU_HIT(DBF_FYL2X);
	SF_BEGIN; SF_set(STV(1), fyl2x(SF_get(TOP), SF_get(STV(1)), st)); SF_END;
	FPU_FPOP();
}
static void FPU_FYL2XP1(void){
	DBFPU_HIT(DBF_FYL2XP1);
	SF_BEGIN; SF_set(STV(1), fyl2xp1(SF_get(TOP), SF_get(STV(1)), st)); SF_END;
	FPU_FPOP();
}

/* ------------------------------------------------------------------ *
 * moves and compares
 * ------------------------------------------------------------------ */

static void FPU_FXCH(Bitu st_, Bitu other){
	FPU_Tag tag = fpu.tags[other];  floatx80 v = SF_get(other);
	fpu.tags[other] = fpu.tags[st_]; SF_set(other, SF_get(st_));
	fpu.tags[st_] = tag;             SF_set(st_, v);
}

static void FPU_FST(Bitu st_, Bitu other){
	fpu.tags[other] = fpu.tags[st_];
	SF_set(other, SF_get(st_));
}

/* FCOM and FUCOM differ in exactly one thing, and it is not the result: they
 * both return "unordered" for a NaN operand and set the same C3/C2/C0.  What
 * differs is whether that raises #IA.
 *
 *   FCOM   signals on ANY NaN, quiet or signalling
 *   FUCOM  signals only on an SNaN; a QNaN compares unordered in silence
 *
 * softfloat3e spells this as the `quiet` argument to extF80_compare(): the
 * SNaN branch raises unconditionally, the QNaN branch raises `if (!quiet)`.
 * Aliasing FUCOM to FCOM and giving both the quiet compare therefore got the
 * pair exactly backwards -- FUCOM behaved correctly and FCOM never signalled.
 *
 * This matters more here than it did in the stock core, because the stock core
 * had no exception machinery at all: honest IE/ES reporting is the reason this
 * file exists, and the compares were the one place still exempt from it.
 *
 * The empty-operand case is a stack fault (#IS): the hardware sets IE and SF
 * and, because DOS masks IE, delivers the unordered result -- so the codes are
 * unchanged from before and only the status word gains bits. */
static void FPU_FCOM_kernel(Bitu st_, Bitu other, bool quiet){
	if (((fpu.tags[st_] != TAG_Valid) && (fpu.tags[st_] != TAG_Zero)) ||
	    ((fpu.tags[other] != TAG_Valid) && (fpu.tags[other] != TAG_Zero))) {
		fpu.sw |= 0x0001 | 0x0040;                     /* IE + SF: stack fault */
		DBFPU_ANOM(DBA_SF); DBFPU_ANOM(DBA_IE);
		if (!(fpu.cw & 0x0001)) fpu.sw |= 0x0080 | 0x8000;   /* ES, B if unmasked */
		FPU_SET_C3(1);FPU_SET_C2(1);FPU_SET_C0(1);return;
	}
	SF_BEGIN;
	int rel = quiet ? extF80_compare_quiet(SF_get(st_), SF_get(other), &st)
	                : extF80_compare      (SF_get(st_), SF_get(other), &st);
	SF_END;
	switch (rel) {
		case softfloat_relation_equal:   FPU_SET_C3(1);FPU_SET_C2(0);FPU_SET_C0(0); break;
		case softfloat_relation_less:    FPU_SET_C3(0);FPU_SET_C2(0);FPU_SET_C0(1); break;
		case softfloat_relation_greater: FPU_SET_C3(0);FPU_SET_C2(0);FPU_SET_C0(0); break;
		default:                         FPU_SET_C3(1);FPU_SET_C2(1);FPU_SET_C0(1); break;
	}
}

static void FPU_FCOM (Bitu st_, Bitu other){ 	DBFPU_HIT(DBF_FCOM);
FPU_FCOM_kernel(st_, other, false); }
static void FPU_FUCOM(Bitu st_, Bitu other){ 	DBFPU_HIT(DBF_FUCOM);
FPU_FCOM_kernel(st_, other, true ); }

static void FPU_FTST(void){
	SF_set(8, i32_to_extF80(0));
	fpu.tags[8] = TAG_Zero;
	FPU_FCOM(TOP,8);
}

static void FPU_FXAM(void){
	DBFPU_HIT(DBF_FXAM);
	floatx80 v = SF_get(TOP);
	FPU_SET_C1((v.signExp & 0x8000) ? 1 : 0);
	if (fpu.tags[TOP] == TAG_Empty) { FPU_SET_C3(1);FPU_SET_C2(0);FPU_SET_C0(1); return; }
	switch (extF80_class(v)) {
		case softfloat_zero:         FPU_SET_C3(1);FPU_SET_C2(0);FPU_SET_C0(0); break;
		case softfloat_SNaN:
		case softfloat_QNaN:         FPU_SET_C3(0);FPU_SET_C2(0);FPU_SET_C0(1); break;
		case softfloat_negative_inf:
		case softfloat_positive_inf: FPU_SET_C3(0);FPU_SET_C2(1);FPU_SET_C0(1); break;
		case softfloat_denormal:     FPU_SET_C3(1);FPU_SET_C2(1);FPU_SET_C0(0); break;
		default:                     FPU_SET_C3(0);FPU_SET_C2(1);FPU_SET_C0(0); break;
	}
}

/* ------------------------------------------------------------------ *
 * constants
 * ------------------------------------------------------------------ */

/* Bit patterns taken from Bochs' fpu_const.cc, not from decimal literals: a
 * decimal constant would be parsed into a double and lose the low bits, which
 * is the whole thing this core exists to avoid.
 *
 * Real x87 nudges these by one ULP depending on the rounding mode, and Bochs
 * reproduces that (FPU_round_const).  Cheap to match, so match it. */
static INLINE floatx80 SF_const(Bit16u se, Bit64u sig, int adj) {
	floatx80 r; r.signExp = se; r.signif = sig + adj; return r;
}
/* RC field is CW bits 11:10; 1 = down, 3 = chop */
static INLINE bool SF_down_or_chop(void) { return (fpu.round == ROUND_Down) || (fpu.round == ROUND_Chop); }
static INLINE int  SF_adj_down(void)     { return SF_down_or_chop() ? -1 : 0; }

static void FPU_FLD1(void)    { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x3FFF, BX_CONST64(0x8000000000000000), 0)); }
static void FPU_FLDL2T(void)  { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x4000, BX_CONST64(0xd49a784bcd1b8afe), (fpu.round == ROUND_Up) ? 1 : 0)); }
static void FPU_FLDL2E(void)  { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x3FFF, BX_CONST64(0xb8aa3b295c17f0bc), SF_adj_down())); }
static void FPU_FLDPI(void)   { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x4000, BX_CONST64(0xc90fdaa22168c235), SF_adj_down())); }
static void FPU_FLDLG2(void)  { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x3FFD, BX_CONST64(0x9a209a84fbcff799), SF_adj_down())); }
static void FPU_FLDLN2(void)  { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x3FFE, BX_CONST64(0xb17217f7d1cf79ac), SF_adj_down())); }
static void FPU_FLDZ(void)    { FPU_PREP_PUSH(); SF_set(TOP, SF_const(0x0000, BX_CONST64(0x0000000000000000), 0));
                                fpu.tags[TOP] = TAG_Zero; }

/* ------------------------------------------------------------------ *
 * environment
 * ------------------------------------------------------------------ */

static void FPU_FSTENV(PhysPt addr){
	FPU_SET_TOP(TOP);
	if(!cpu.code.big) {
		mem_writew(addr+0,static_cast<Bit16u>(fpu.cw));
		mem_writew(addr+2,static_cast<Bit16u>(fpu.sw));
		mem_writew(addr+4,static_cast<Bit16u>(FPU_GetTag()));
	} else {
		mem_writed(addr+0,static_cast<Bit32u>(fpu.cw));
		mem_writed(addr+4,static_cast<Bit32u>(fpu.sw));
		mem_writed(addr+8,static_cast<Bit32u>(FPU_GetTag()));
	}
}

static void FPU_FLDENV(PhysPt addr){
	Bit16u tag; Bit32u tagbig; Bitu cw;
	if(!cpu.code.big) {
		cw     = mem_readw(addr+0);
		fpu.sw = mem_readw(addr+2);
		tag    = mem_readw(addr+4);
	} else {
		cw     = mem_readd(addr+0);
		fpu.sw = (Bit16u)mem_readd(addr+4);
		tagbig = mem_readd(addr+8);
		tag    = static_cast<Bit16u>(tagbig);
	}
	FPU_SetTag(tag);
	FPU_SetCW(cw);
	TOP = FPU_GET_TOP();
}

static void FPU_FSAVE(PhysPt addr){
	FPU_FSTENV(addr);
	Bitu start = (cpu.code.big?28:14);
	for(Bitu i = 0;i < 8;i++){ FPU_ST80(addr+start,STV(i)); start += 10; }
	FPU_FINIT();
}

static void FPU_FRSTOR(PhysPt addr){
	FPU_FLDENV(addr);
	Bitu start = (cpu.code.big?28:14);
	for(Bitu i = 0;i < 8;i++){ SF_set(STV(i), FPU_FLD80(addr+start)); start += 10; }
}

static INLINE void FPU_FADD_EA(Bitu op1)  { FPU_FADD(op1,8); }
static INLINE void FPU_FMUL_EA(Bitu op1)  { FPU_FMUL(op1,8); }
static INLINE void FPU_FSUB_EA(Bitu op1)  { FPU_FSUB(op1,8); }
static INLINE void FPU_FSUBR_EA(Bitu op1) { FPU_FSUBR(op1,8); }
static INLINE void FPU_FDIV_EA(Bitu op1)  { FPU_FDIV(op1,8); }
static INLINE void FPU_FDIVR_EA(Bitu op1) { FPU_FDIVR(op1,8); }
static INLINE void FPU_FCOM_EA(Bitu op1)  { FPU_FCOM(op1,8); }
