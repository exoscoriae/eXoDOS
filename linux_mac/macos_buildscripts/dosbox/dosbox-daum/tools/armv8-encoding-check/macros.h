// registers
#define HOST_r0		 0
#define HOST_r1		 1
#define HOST_r2		 2
#define HOST_r3		 3
#define HOST_r4		 4
#define HOST_r5		 5
#define HOST_r6		 6
#define HOST_r7		 7
#define HOST_r8		 8
#define HOST_r9		 9
#define HOST_r10	10
#define HOST_r11	11
#define HOST_r12	12
#define HOST_r13	13
#define HOST_r14	14
#define HOST_r15	15
#define HOST_r16	16
#define HOST_r17	17
#define HOST_r18	18
#define HOST_r19	19
#define HOST_r20	20
#define HOST_r21	21
#define HOST_r22	22
#define HOST_r23	23
#define HOST_r24	24
#define HOST_r25	25
#define HOST_r26	26
#define HOST_r27	27
#define HOST_r28	28
#define HOST_r29	29
#define HOST_r30	30
// special registers
#define HOST_sp		31
#define HOST_zr		31

// register aliases
// 32-bit registers
#define HOST_w0		HOST_r0
#define HOST_w1		HOST_r1
#define HOST_w2		HOST_r2
#define HOST_w3		HOST_r3
#define HOST_w4		HOST_r4
#define HOST_w5		HOST_r5
#define HOST_w6		HOST_r6
#define HOST_w7		HOST_r7
#define HOST_w8		HOST_r8
#define HOST_w9		HOST_r9
#define HOST_w10	HOST_r10
#define HOST_w11	HOST_r11
#define HOST_w12	HOST_r12
#define HOST_w13	HOST_r13
#define HOST_w14	HOST_r14
#define HOST_w15	HOST_r15
#define HOST_w16	HOST_r16
#define HOST_w17	HOST_r17
#define HOST_w18	HOST_r18
#define HOST_w19	HOST_r19
#define HOST_w20	HOST_r20
#define HOST_w21	HOST_r21
#define HOST_w22	HOST_r22
#define HOST_w23	HOST_r23
#define HOST_w24	HOST_r24
#define HOST_w25	HOST_r25
#define HOST_w26	HOST_r26
#define HOST_w27	HOST_r27
#define HOST_w28	HOST_r28
#define HOST_w29	HOST_r29
#define HOST_w30	HOST_r30
#define HOST_wsp	HOST_sp
#define HOST_wzr	HOST_zr
// 64-bit registers
#define HOST_x0		HOST_r0
#define HOST_x1		HOST_r1
#define HOST_x2		HOST_r2
#define HOST_x3		HOST_r3
#define HOST_x4		HOST_r4
#define HOST_x5		HOST_r5
#define HOST_x6		HOST_r6
#define HOST_x7		HOST_r7
#define HOST_x8		HOST_r8
#define HOST_x9		HOST_r9
#define HOST_x10	HOST_r10
#define HOST_x11	HOST_r11
#define HOST_x12	HOST_r12
#define HOST_x13	HOST_r13
#define HOST_x14	HOST_r14
#define HOST_x15	HOST_r15
#define HOST_x16	HOST_r16
#define HOST_x17	HOST_r17
#define HOST_x18	HOST_r18
#define HOST_x19	HOST_r19
#define HOST_x20	HOST_r20
#define HOST_x21	HOST_r21
#define HOST_x22	HOST_r22
#define HOST_x23	HOST_r23
#define HOST_x24	HOST_r24
#define HOST_x25	HOST_r25
#define HOST_x26	HOST_r26
#define HOST_x27	HOST_r27
#define HOST_x28	HOST_r28
#define HOST_x29	HOST_r29
#define HOST_x30	HOST_r30
#define HOST_xzr	HOST_zr
#define HOST_ip0	HOST_r16
#define HOST_ip1	HOST_r17
#define HOST_fp		HOST_r29
#define HOST_lr		HOST_r30


// temporary registers
#define temp1 HOST_r10
#define temp2 HOST_r11
#define temp3 HOST_r12

// register that holds function return values
#define FC_RETOP HOST_r0

// register used for address calculations,
#define FC_ADDR HOST_r19			// has to be saved across calls, see DRC_PROTECT_ADDR_REG

// register that holds the first parameter
#define FC_OP1 HOST_r0

// register that holds the second parameter
#define FC_OP2 HOST_r1

// special register that holds the third parameter for _R3 calls (byte accessible)
#define FC_OP3 HOST_r2

// register that holds byte-accessible temporary values
#define FC_TMP_BA1 HOST_r0

// register that holds byte-accessible temporary values
#define FC_TMP_BA2 HOST_r1

// temporary register for LEA
#define TEMP_REG_DRC HOST_r9

// used to hold the address of "cpu_regs" - preferably filled in function gen_run_code
#define FC_REGS_ADDR HOST_r20

// used to hold the address of "Segs" - preferably filled in function gen_run_code
#define FC_SEGS_ADDR HOST_r21

// used to hold the address of "core_dynrec.readdata" - filled in function gen_run_code
#define readdata_addr HOST_r22


// instruction encodings

// move
// mov dst, src, lsl #imm
#define MOV_REG_LSL_IMM(dst, src, imm) ORR_REG_LSL_IMM(dst, HOST_wzr, src, imm)
// movz dst, #(imm lsl simm)		@	0 <= imm <= 65535	&	simm = 0/16
#define MOVZ(dst, imm, simm) (0x52800000 + (dst) + ((imm) << 5) + ((simm)?0x00200000:0) )
// movn dst, #(imm lsl simm)		@	0 <= imm <= 65535	&	simm = 0/16
#define MOVN(dst, imm, simm) (0x12800000 + (dst) + ((imm) << 5) + ((simm)?0x00200000:0) )
// movk dst, #(imm lsl simm)		@	0 <= imm <= 65535	&	simm = 0/16
#define MOVK(dst, imm, simm) (0x72800000 + (dst) + ((imm) << 5) + ((simm)?0x00200000:0) )
// movz dst, #(imm lsl simm)		@	0 <= imm <= 65535	&	simm = 0/16/32/48
#define MOVZ64(dst, imm, simm) (0xd2800000 + (dst) + ((imm) << 5) + (((simm) >> 4) << 21) )
// movk dst, #(imm lsl simm)		@	0 <= imm <= 65535	&	simm = 0/16/32/48
#define MOVK64(dst, imm, simm) (0xf2800000 + (dst) + ((imm) << 5) + (((simm) >> 4) << 21) )
// lslv dst, src, rreg
#define LSLV(dst, src, rreg) (0x1ac02000 + (dst) + ((src) << 5) + ((rreg) << 16) )
// lsrv dst, src, rreg
#define LSRV(dst, src, rreg) (0x1ac02400 + (dst) + ((src) << 5) + ((rreg) << 16) )
// asrv dst, src, rreg
#define ASRV(dst, src, rreg) (0x1ac02800 + (dst) + ((src) << 5) + ((rreg) << 16) )
// rorv dst, src, rreg
#define RORV(dst, src, rreg) (0x1ac02c00 + (dst) + ((src) << 5) + ((rreg) << 16) )
// lslv dst, src, rreg
#define LSLV64(dst, src, rreg) (0x9ac02000 + (dst) + ((src) << 5) + ((rreg) << 16) )
// lsrv dst, src, rreg
#define LSRV64(dst, src, rreg) (0x9ac02400 + (dst) + ((src) << 5) + ((rreg) << 16) )
// lsr dst, src, #imm
#define LSR64_IMM(dst, src, imm) UBFM64(dst, src, imm, 63)

// arithmetic
// add dst, src, #(imm lsl simm)		@	0 <= imm <= 4095	&	simm = 0/12
#define ADD_IMM(dst, src, imm, simm) (0x11000000 + (dst) + ((src) << 5) + ((imm) << 10) + ((simm)?0x00400000:0) )
// add dst, src1, src2, lsl #imm
#define ADD_REG_LSL_IMM(dst, src1, src2, imm) (0x0b000000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )
// sub dst, src, #(imm lsl simm)		@	0 <= imm <= 4095	&	simm = 0/12
#define SUB_IMM(dst, src, imm, simm) (0x51000000 + (dst) + ((src) << 5) + ((imm) << 10) + ((simm)?0x00400000:0) )
// sub dst, src1, src2, lsl #imm
#define SUB_REG_LSL_IMM(dst, src1, src2, imm) (0x4b000000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )
// cmp src, #(imm lsl simm)		@	0 <= imm <= 4095	&	simm = 0/12
#define CMP_IMM(src, imm, simm) (0x7100001f + ((src) << 5) + ((imm) << 10) + ((simm)?0x00400000:0) )
// nop
#define NOP (0xd503201f)

// logical
// and dst, src1, src2, lsl #imm		@	0 <= imm <= 31
#define AND_REG_LSL_IMM(dst, src1, src2, imm) (0x0a000000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )
// orr dst, src1, src2, lsl #imm		@	0 <= imm <= 31
#define ORR_REG_LSL_IMM(dst, src1, src2, imm) (0x2a000000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )
// eor dst, src1, src2, lsl #imm		@	0 <= imm <= 31
#define EOR_REG_LSL_IMM(dst, src1, src2, imm) (0x4a000000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )
// bic dst, src1, src2, lsl #imm		@	0 <= imm <= 31
#define BIC_REG_LSL_IMM(dst, src1, src2, imm) (0x0a200000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )
// and dst, src1, src2, lsl #imm		@	0 <= imm <= 63
#define AND64_REG_LSL_IMM(dst, src1, src2, imm) (0x8a000000 + (dst) + ((src1) << 5) + ((src2) << 16) + ((imm) << 10) )

// load
// ldr reg, [pc, #imm]		@	-1M <= imm < 1M	&	imm mod 4 = 0
#define LDR64_PC(reg, imm) (0x58000000 + (reg) + (((imm) << 3) & 0x00ffffe0) )
/* ldp/stp take a SIGNED imm7 at bits 21:15, scaled by 8, so a negative offset
 * sign-extends the whole way up through the opcode.  `(imm) << 12` alone spills
 * into bits 22+ and, because these macros add rather than or, corrupts the
 * instruction: LDP with #-64 came out as a97c0861's sibling a93c0861, which is
 * an STP -- the L bit cleared, a load silently turned into a store.  STP with
 * #-64 came out as a post-indexed STP that writes back to the base register.
 *
 * Every other signed-offset macro here (LDUR*, STUR*) already masks its field;
 * these two were the only ones that did not.  Verified against
 * aarch64-linux-gnu-as: see audit/armv8-encoding-check.
 *
 * Currently only ever called with +16 and +32, so this was latent -- but it is
 * a landmine in the one file nothing else covers. */
// ldp reg1, reg2 [addr, #imm]		@	-512 <= imm < 512	&	imm mod 8 = 0
#define LDP64_IMM(reg1, reg2, addr, imm) (0xa9400000 + (reg1) + ((reg2) << 10) + ((addr) << 5) + (((imm) << 12) & 0x003f8000) )
// ldr reg, [addr, #imm]		@	0 <= imm < 32768	&	imm mod 8 = 0
#define LDR64_IMM(reg, addr, imm) (0xf9400000 + (reg) + ((addr) << 5) + ((imm) << 7) )
// ldr reg, [addr, #imm]		@	0 <= imm < 16384	&	imm mod 4 = 0
#define LDR_IMM(reg, addr, imm) (0xb9400000 + (reg) + ((addr) << 5) + ((imm) << 8) )
// ldrh reg, [addr, #imm]		@	0 <= imm < 8192	&	imm mod 2 = 0
#define LDRH_IMM(reg, addr, imm) (0x79400000 + (reg) + ((addr) << 5) + ((imm) << 9) )
// ldrb reg, [addr, #imm]		@	0 <= imm < 4096
#define LDRB_IMM(reg, addr, imm) (0x39400000 + (reg) + ((addr) << 5) + ((imm) << 10) )
// ldr reg, [addr1, addr2, lsl #imm]		@	imm = 0/2
#define LDR64_REG_LSL_IMM(reg, addr1, addr2, imm) (0xf8606800 + (reg) + ((addr1) << 5) + ((addr2) << 16) + ((imm)?0x00001000:0) )
// ldur reg, [addr, #imm]		@	-256 <= imm < 256
#define LDUR64_IMM(reg, addr, imm) (0xf8400000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )
// ldur reg, [addr, #imm]		@	-256 <= imm < 256
#define LDUR_IMM(reg, addr, imm) (0xb8400000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )
// ldurh reg, [addr, #imm]		@	-256 <= imm < 256
#define LDURH_IMM(reg, addr, imm) (0x78400000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )
// ldurb reg, [addr, #imm]		@	-256 <= imm < 256
#define LDURB_IMM(reg, addr, imm) (0x38400000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )

// store
// stp reg1, reg2 [addr, #imm]		@	-512 <= imm < 512	&	imm mod 8 = 0
// (signed imm7 -- see the note on LDP64_IMM above for why this is masked)
#define STP64_IMM(reg1, reg2, addr, imm) (0xa9000000 + (reg1) + ((reg2) << 10) + ((addr) << 5) + (((imm) << 12) & 0x003f8000) )
// str reg, [addr, #imm]		@	0 <= imm < 32768	&	imm mod 8 = 0
#define STR64_IMM(reg, addr, imm) (0xf9000000 + (reg) + ((addr) << 5) + ((imm) << 7) )
// str reg, [addr, #imm]		@	0 <= imm < 16384	&	imm mod 4 = 0
#define STR_IMM(reg, addr, imm) (0xb9000000 + (reg) + ((addr) << 5) + ((imm) << 8) )
// strh reg, [addr, #imm]		@	0 <= imm < 8192	&	imm mod 2 = 0
#define STRH_IMM(reg, addr, imm) (0x79000000 + (reg) + ((addr) << 5) + ((imm) << 9) )
// strb reg, [addr, #imm]		@	0 <= imm < 4096
#define STRB_IMM(reg, addr, imm) (0x39000000 + (reg) + ((addr) << 5) + ((imm) << 10) )
// stur reg, [addr, #imm]		@	-256 <= imm < 256
#define STUR64_IMM(reg, addr, imm) (0xf8000000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )
// stur reg, [addr, #imm]		@	-256 <= imm < 256
#define STUR_IMM(reg, addr, imm) (0xb8000000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )
// sturh reg, [addr, #imm]		@	-256 <= imm < 256
#define STURH_IMM(reg, addr, imm) (0x78000000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )
// sturb reg, [addr, #imm]		@	-256 <= imm < 256
#define STURB_IMM(reg, addr, imm) (0x38000000 + (reg) + ((addr) << 5) + (((imm) << 12) & 0x001ff000) )

// branch
/* The displacement fields are masked for the same reason as LDP/STP above: an
 * out-of-range or negative distance must not be able to reach the opcode or the
 * condition field.  gen_fill_branch() and gen_fill_branch_long() -- which are
 * where a *runtime-computed* distance actually lands -- already mask with these
 * exact values; the raw macros did not, and only escaped it because their call
 * sites all pass a literal 0 or 8.  Masking here makes the two agree, so a
 * displacement that is out of range produces a wrong branch target rather than
 * a different instruction. */
// bgt pc+imm		@	0 <= imm < 1M	&	imm mod 4 = 0
#define BGT_FWD(imm) (0x5400000c + (((imm) << 3) & 0x00ffffe0) )
// b pc+imm		@	0 <= imm < 128M	&	imm mod 4 = 0
#define B_FWD(imm) (0x14000000 + (((imm) >> 2) & 0x03ffffff) )
// br reg
#define BR(reg) (0xd61f0000 + ((reg) << 5) )
// blr reg
#define BLR_REG(reg) (0xd63f0000 + ((reg) << 5) )
// cbz reg, pc+imm		@	0 <= imm < 1M	&	imm mod 4 = 0
#define CBZ_FWD(reg, imm) (0x34000000 + (reg) + (((imm) << 3) & 0x00ffffe0) )
// cbnz reg, pc+imm		@	0 <= imm < 1M	&	imm mod 4 = 0
#define CBNZ_FWD(reg, imm) (0x35000000 + (reg) + (((imm) << 3) & 0x00ffffe0) )
// ret reg
#define RET_REG(reg) (0xd65f0000 + ((reg) << 5) )
// ret
#define RET RET_REG(HOST_x30)

// extend
// sxth dst, src
#define SXTH(dst, src) SBFM(dst, src, 0, 15)
// sxtb dst, src
#define SXTB(dst, src) SBFM(dst, src, 0, 7)
// uxth dst, src
#define UXTH(dst, src) UBFM(dst, src, 0, 15)
// uxtb dst, src
#define UXTB(dst, src) UBFM(dst, src, 0, 7)

// bit field
// bfi dst, src, #lsb, #width		@	lsb >= 0, width >= 1, lsb+width <= 32
#define BFI(dst, src, lsb, width) BFM(dst, src, (32 - (lsb)) & 0x1f, (width) - 1)
// bfm dst, src, #rimm, #simm		@	0 <= rimm < 32, 0 <= simm < 32
#define BFM(dst, src, rimm, simm) (0x33000000 + (dst) + ((src) << 5) + ((rimm) << 16) + ((simm) << 10) )
// sbfm dst, src, #rimm, #simm		@	0 <= rimm < 32, 0 <= simm < 32
#define SBFM(dst, src, rimm, simm) (0x13000000 + (dst) + ((src) << 5) + ((rimm) << 16) + ((simm) << 10) )
// ubfm dst, src, #rimm, #simm		@	0 <= rimm < 32, 0 <= simm < 32
#define UBFM(dst, src, rimm, simm) (0x53000000 + (dst) + ((src) << 5) + ((rimm) << 16) + ((simm) << 10) )
// bfi dst, src, #lsb, #width		@	lsb >= 0, width >= 1, lsb+width <= 64
#define BFI64(dst, src, lsb, width) BFM64(dst, src, (64 - (lsb)) & 0x3f, (width) - 1)
// bfm dst, src, #rimm, #simm		@	0 <= rimm < 64, 0 <= simm < 64
#define BFM64(dst, src, rimm, simm) (0xb3400000 + (dst) + ((src) << 5) + ((rimm) << 16) + ((simm) << 10) )
// ubfm dst, src, #rimm, #simm		@	0 <= rimm < 64, 0 <= simm < 64
#define UBFM64(dst, src, rimm, simm) (0xd3400000 + (dst) + ((src) << 5) + ((rimm) << 16) + ((simm) << 10) )


// move a full register from reg_src to reg_dst
