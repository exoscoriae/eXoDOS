#include <stdint.h>
#include <cstdio>
#include <cstring>
#define INLINE inline
/* dosbox.h provides these to every real translation unit; the soft-float core
   uses GCC_UNLIKELY on its stack-fault checks exactly as fpu_instructions.h
   does.  The harness has to supply them or it stops being a stand-in for the
   environment the header actually compiles in. */
#ifndef GCC_UNLIKELY
#define GCC_UNLIKELY(x) (x)
#endif
#ifndef GCC_LIKELY
#define GCC_LIKELY(x) (x)
#endif
typedef uint8_t Bit8u; typedef uint16_t Bit16u; typedef uint32_t Bit32u;
typedef int16_t Bit16s; typedef int32_t Bit32s; typedef uint64_t Bit64u; typedef int64_t Bit64s;
typedef uintptr_t Bitu; typedef uint32_t PhysPt;
enum FPU_Tag { TAG_Valid=0, TAG_Zero=1, TAG_Weird=2, TAG_Empty=3 };
enum FPU_Round { ROUND_Nearest=0, ROUND_Down=1, ROUND_Up=2, ROUND_Chop=3 };
typedef union { double d; struct { Bit32u lower; Bit32s upper; } l; Bit64s ll; } FPU_Reg;
typedef struct { Bit32u m1,m2; Bit16u m3; Bit16u d1; Bit32u d2; } FPU_P_Reg;
typedef struct { FPU_Reg regs[9]; FPU_P_Reg p_regs[9]; FPU_Tag tags[9];
  Bit16u cw, cw_mask_all, sw; Bit32u top; FPU_Round round; } FPU_rec;
extern FPU_rec fpu;
static Bitu TOP = 0;
#define STV(i) ((TOP + (i)) & 7)
static INLINE void FPU_SetCW(Bitu w){ fpu.cw=(Bit16u)w; fpu.cw_mask_all=(Bit16u)(w|0x3f); fpu.round=(FPU_Round)((w>>10)&3); }
static INLINE Bitu FPU_GET_TOP(void){ return (fpu.sw & 0x3800)>>11; }
static INLINE void FPU_SET_TOP(Bitu v){ fpu.sw &= ~0x3800; fpu.sw |= (v&7)<<11; }
static INLINE void FPU_SET_C0(Bitu v){ fpu.sw &= ~0x0100; if(v) fpu.sw |= 0x0100; }
static INLINE void FPU_SET_C1(Bitu v){ fpu.sw &= ~0x0200; if(v) fpu.sw |= 0x0200; }
static INLINE void FPU_SET_C2(Bitu v){ fpu.sw &= ~0x0400; if(v) fpu.sw |= 0x0400; }
static INLINE void FPU_SET_C3(Bitu v){ fpu.sw &= ~0x4000; if(v) fpu.sw |= 0x4000; }
static INLINE void FPU_SetTag(Bit16u t){ for(Bitu i=0;i<8;i++) fpu.tags[i]=(FPU_Tag)((t>>(2*i))&3); }
static INLINE Bit16u FPU_GetTag(void){ Bit16u t=0; for(Bitu i=0;i<8;i++) t |= ((fpu.tags[i]&3)<<(2*i)); return t; }
extern Bit8u guestmem[1<<16];
static INLINE Bit8u  mem_readb(PhysPt a){ return guestmem[a]; }
static INLINE Bit16u mem_readw(PhysPt a){ Bit16u v; memcpy(&v,guestmem+a,2); return v; }
static INLINE Bit32u mem_readd(PhysPt a){ Bit32u v; memcpy(&v,guestmem+a,4); return v; }
static INLINE void mem_writeb(PhysPt a,Bit8u v){ guestmem[a]=v; }
static INLINE void mem_writew(PhysPt a,Bit16u v){ memcpy(guestmem+a,&v,2); }
static INLINE void mem_writed(PhysPt a,Bit32u v){ memcpy(guestmem+a,&v,4); }
struct { struct { bool big; } code; } cpu = {{false}};
