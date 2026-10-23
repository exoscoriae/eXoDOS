/* Minimal stand-in for Bochs' generated config.h.
 * softfloat3e references exactly three Bochs macros; nothing else. */
#ifndef BOCHS_CONFIG_SHIM_H
#define BOCHS_CONFIG_SHIM_H
#include <stdint.h>
#define BX_CPP_INLINE inline
/* Bochs does not ship s_approxRecip32_1; its divides expect the host to have a
   native 64/32 divide.  True on both x86_64 and arm64. */
#define SOFTFLOAT_FAST_DIV64TO32 1
#define SOFTFLOAT_FAST_DIV32TO16 1
#define BX_CONST64(x) (x##ULL)
#if defined(__BIG_ENDIAN__) || (defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
#  define BX_BIG_ENDIAN 1
#else
#  define BX_LITTLE_ENDIAN 1
#endif
typedef uint8_t Bit8u;   typedef int8_t  Bit8s;
typedef uint16_t Bit16u; typedef int16_t Bit16s;
typedef uint32_t Bit32u; typedef int32_t Bit32s;
typedef uint64_t Bit64u; typedef int64_t Bit64s;
#endif
