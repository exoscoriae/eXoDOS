/* Stand-in for Bochs' generated config.h, for the x87 transcendentals.
 *
 * These translation units are compiled into libsoftfloat and never include any
 * Daum header, so defining the Bit* types here cannot collide with Daum's. */
#ifndef BOCHS_X87_SHIM_H
#define BOCHS_X87_SHIM_H
#include "../softfloat3e/include/bochs_shim_config.h"
typedef uint8_t  Bit8u;   typedef int8_t  Bit8s;
typedef uint16_t Bit16u;  typedef int16_t Bit16s;
typedef uint32_t Bit32u;  typedef int32_t Bit32s;
typedef uint64_t Bit64u;  typedef int64_t Bit64s;
#endif
