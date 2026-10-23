	movz w3, #4660
	movz w3, #4660, lsl #16
	movn w5, #65535
	movk w7, #43981, lsl #16
	movz x9, #4660, lsl #32
	movz x9, #4660, lsl #48
	movk x2, #43981, lsl #48
	lslv w1, w2, w3
	lsrv w1, w2, w3
	asrv w1, w2, w3
	rorv w1, w2, w3
	lslv x4, x5, x6
	lsrv x4, x5, x6
	lsr x8, x9, #17
	add w1, w2, #291
	add w1, w2, #291, lsl #12
	add w1, w2, w3, lsl #7
	sub w1, w2, #291
	sub w1, w2, w3, lsl #7
	cmp w4, #291
	cmp w4, #291, lsl #12
	and w1, w2, w3, lsl #5
	orr w1, w2, w3, lsl #5
	eor w1, w2, w3, lsl #5
	bic w1, w2, w3, lsl #5
	and x1, x2, x3, lsl #40
	mov w9, w10, lsl #3
	ldp x1, x2, [x3, #64]
	ldp x1, x2, [x3, #-64]
	ldr x1, [x2, #4088]
	ldr w1, [x2, #2044]
	ldrh w1, [x2, #1022]
	ldrb w1, [x2, #511]
	ldr x1, [x2, x3, lsl #3]
	ldr x1, [x2, x3]
	ldur x1, [x2, #-8]
	ldur w1, [x2, #-8]
	ldurh w1, [x2, #-8]
	ldurb w1, [x2, #-8]
	stp x1, x2, [x3, #-64]
	str x1, [x2, #4088]
	str w1, [x2, #2044]
	strh w1, [x2, #1022]
	strb w1, [x2, #511]
	stur x1, [x2, #-8]
	stur w1, [x2, #-8]
	sturh w1, [x2, #-8]
	sturb w1, [x2, #-8]
	br x5
	blr x5
	ret x30
	sxth w1, w2
	sxtb w1, w2
	uxth w1, w2
	uxtb w1, w2
	bfi w1, w2, #5, #7
	bfi x1, x2, #5, #7
	bfi w1, w2, #0, #8
	bfi x1, x2, #0, #8
	sbfm w1, w2, #3, #9
	ubfm w1, w2, #3, #9
	bfm  w1, w2, #3, #9
	bfm  x1, x2, #3, #9
	ubfm x1, x2, #3, #9
	ldp x1, x2, [x3, #-64]
	ldp x1, x2, [x3, #-512]
	ldp x5, x6, [sp, #504]
	stp x1, x2, [x3, #-64]
	stp x1, x2, [x3, #-512]
	stp x19, x20, [sp, #16]
	stp x21, x22, [sp, #32]
	ldp x19, x20, [sp, #16]
	ldp x21, x22, [sp, #32]
	b   . + 8
	b   . + 0x3fffffc
	bgt . + 8
	bgt . + 0xffffc
	cbz w5, . + 8
	cbnz w5, . + 0xffffc
	ldr x1, .-256
