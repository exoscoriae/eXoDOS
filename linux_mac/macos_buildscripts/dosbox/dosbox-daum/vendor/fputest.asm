; fputest.asm -- the OLE2DISP.DLL precision check, as a DOS .COM
;
; OLE2DISP.DLL 2.3.3027.1 (the OLE layer of Windows 3.1x) detects a
; reduced-precision FPU with exactly this sequence: FILD a 64-bit integer,
; FBSTP it to packed BCD, and compare the low digits.  When they come back
; wrong it pops an extra stack entry, and DOSBox -- which does not deliver FPU
; exceptions to the guest -- aborts emulation.  That is why Windows 3.1 OLE
; applications die on a DOSBox whose FPU computes in `double`.
;
; A 64-bit integer needs a 64-bit significand to survive the round trip.  x87
; has one; a `double` has 53.  So:
;
;   correct (80-bit)     0999517642299539456
;   double core          0999517642299539600
;
; The result is written to RESULT.TXT on the current drive rather than to the
; screen, because DOSBox's screen output is emulated and cannot be read from
; the host -- the same reason the core=dynamic check writes to a mounted drive.
;
; Assembled by lib/daum.sh with the nasm the build already provides:
;   nasm -f bin fputest.asm -o fputest.com

        org     100h

start:
        fild    qword [input]           ; the value OLE2DISP tests with
        fbstp   tword [output]          ; -> 10 bytes of packed BCD
        fwait

        ; unpack 10 BCD bytes into 20 ASCII digits, most significant first.
        ; byte 9's high nibble is the sign, which prints as '0' when positive.
        mov     di, ascii
        mov     si, output+9
        mov     cx, 10
unpack:
        mov     al, [si]
        mov     ah, al
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        and     al, 0Fh
        add     al, '0'
        mov     [di], al
        inc     di
        mov     al, ah
        and     al, 0Fh
        add     al, '0'
        mov     [di], al
        inc     di
        dec     si
        loop    unpack

        mov     byte [ascii+20], 0Dh
        mov     byte [ascii+21], 0Ah

; ---------------------------------------------------------------------------
; Second check: FPREM versus FPREM1.
;
; They differ only in how the quotient is rounded before the multiply-subtract
; -- FPREM truncates toward zero, FPREM1 rounds to nearest even -- and 5 rem 3
; is the smallest case that separates them:
;
;       FPREM (5,3) = 5 - 1*3 =  2
;       FPREM1(5,3) = 5 - 2*3 = -1
;
; A core that aliases the two returns -1 for both, which is what C's fmod()
; would then return for fmod(5.0,3.0).  Writing both values out makes the
; difference something the emulator demonstrates rather than something the
; source is argued to imply.
; ---------------------------------------------------------------------------
        finit

        fild    dword [three]           ; ST0=3
        fild    dword [five]            ; ST0=5  ST1=3
        fprem                           ; ST0 = 5 rem 3, truncated quotient
        fistp   word [rem0]             ; -> expect 2
        fstp    st0                     ; drop the divisor

        fild    dword [three]
        fild    dword [five]
        fprem1                          ; ST0 = 5 rem 3, nearest quotient
        fistp   word [rem1]             ; -> expect -1
        fstp    st0
        fwait

        ; format as "  2 -1" -- fixed width, so the verifier can match exactly
        mov     di, ascii+22
        mov     ax, [rem0]
        call    put_int
        mov     byte [di], ' '
        inc     di
        mov     ax, [rem1]
        call    put_int
        mov     byte [di], 0Dh
        inc     di
        mov     byte [di], 0Ah
        inc     di

; ---------------------------------------------------------------------------
; Third check: a MASKED overflow must produce infinity.
;
; SoftFloat consults the control word's mask bits while rounding.  With
; overflow unmasked it takes the x87 wrap branch (exponent biased down by
; 24576, for a trap handler to unpick); with it masked -- which is how DOS
; boots, CW=0x37F -- the answer is +INF.  Declaring everything unmasked
; therefore turns every overflow into a wrapped finite number, and nothing
; anywhere would say so.
;
; big is 2^16000, so big*big overflows the 15-bit exponent.  FXAM reports
; infinity as C3=0 C2=1 C0=1, i.e. (status word & 4500h) == 0500h -- pinned in
; vendor/bochs-fpu/test/test.cc so this encoding is not a guess.
;
; Writes "I0": I for infinity (F if finite), then ES, which must be 0 because
; the exception is masked.
; ---------------------------------------------------------------------------
        finit
        fld     tword [big]
        fld     tword [big]
        fmulp   st1, st0
        fxam
        fnstsw  ax
        mov     bx, ax                  ; keep the whole word for the ES test
        and     ax, 4500h               ; C3 | C2 | C0
        cmp     ax, 0500h               ; C2 and C0 set, C3 clear = infinity
        mov     al, 'F'
        jne     .notinf
        mov     al, 'I'
.notinf:
        mov     [di], al
        inc     di
        mov     al, '0'
        test    bl, 80h                 ; ES -- must stay clear when masked
        jz      .noes
        mov     al, '1'
.noes:
        mov     [di], al
        inc     di
        mov     byte [di], 0Dh
        inc     di
        mov     byte [di], 0Ah
        inc     di

        ; RESULT.TXT <- the 20 digits, then the two remainders, then "I0"
        mov     ah, 3Ch                 ; create
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      done
        mov     bx, ax
        mov     ah, 40h                 ; write
        mov     cx, di
        sub     cx, ascii
        mov     dx, ascii
        int     21h
        mov     ah, 3Eh                 ; close
        int     21h
done:
        int     20h

; put_int -- AX as signed decimal at [DI], advancing DI.  Values here are
; single digits with an optional sign, so no general division loop is needed.
put_int:
        test    ax, ax
        jns     .positive
        mov     byte [di], '-'
        inc     di
        neg     ax
.positive:
        add     al, '0'
        mov     [di], al
        inc     di
        ret

; 0x0DDF000000000000 = 999517642299539456, little-endian
input:   times 6 db 0
         db 0DFh, 00Dh
output:  times 10 db 0
five:    dd 5
three:   dd 3
rem0:    dw 0
rem1:    dw 0
; 2^16000 as an 80-bit extended: exponent field 3FFFh + 16000 = 7E7Fh, and the
; explicit integer bit set.  Squaring it needs exponent 3FFFh + 32000, past the
; 7FFEh maximum, so the multiply overflows.
big:     dq 08000000000000000h
         dw 07E7Fh
ascii:   times 40 db 0
fname:   db "RESULT.TXT", 0
