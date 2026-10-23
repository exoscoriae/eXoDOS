/* Stand-in for Bochs' generated config.h, for SoftFloat-3e only.
 *
 * NO Bit8u/Bit16u/... typedefs here, deliberately.  This header is reached from
 * fpu.cpp via fpu_instructions_softfloat.h, and by then Daum's own generated
 * config.h has already defined those names -- as `unsigned long`, where a
 * uint64_t is `unsigned long long` on this target.  Defining them again is a
 * typedef redefinition error, which is exactly how the first build failed.
 *
 * SoftFloat-3e needs none of them; it uses stdint types throughout.  The x87
 * layer does need them and gets them from x87_config.h, which is only ever
 * included by translation units that never see Daum's headers.
 */
#ifndef BOCHS_SF3E_SHIM_H
#define BOCHS_SF3E_SHIM_H
#include <stdint.h>
#define BX_CPP_INLINE inline
#define BX_CONST64(x) (x##ULL)
/* Bochs does not ship s_approxRecip32_1; its divides expect a native 64/32
   divide, which both x86_64 and arm64 have. */
#define SOFTFLOAT_FAST_DIV64TO32 1
#define SOFTFLOAT_FAST_DIV32TO16 1
#if defined(__BIG_ENDIAN__) || (defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
#  define BX_BIG_ENDIAN 1
#else
#  define BX_LITTLE_ENDIAN 1
#endif
#endif
