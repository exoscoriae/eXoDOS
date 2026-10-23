# FPU core tests

Runs the new soft-float core against a harness that mimics Daum's environment
(the `fpu` struct, `mem_read*`/`mem_write*`, `TOP`, `STV`, the C0..C3 setters),
so the entry points are exercised exactly as `fpu.cpp` calls them.

Run from `vendor/bochs-fpu/`, after copying the header next to the sources:

    cp ../fpu_instructions_softfloat.h .
    g++ -std=c++11 -O2 -w -I . -I test -I shim \
        -I softfloat3e/include -I softfloat3e/8086-SSE -I x87 \
        test/test.cc test/tu2.cc x87/*.cc softfloat3e/*.cc \
        softfloat3e/8086-SSE/*.cc -o test && ./test

`tu2.cc` is a second translation unit that includes the same header and takes
the address of the 24 entry points `core_dynrec/dyn_fpu.h` emits calls to. It
does not test arithmetic — it tests that the header can be included twice
without a duplicate symbol, and that the entry points survive as addressable
functions. Both became load-bearing when the dynamic recompiler was moved onto
this core; see *The dynamic core had its own FPU* below.

| mutation | caught |
|---|---|
| an entry point loses `static` | yes — multiple definition at link |
| an entry point is renamed away | yes — undeclared in `tu2.cc` |

The headline case is the one that matters:

    FILD/FBSTP exact (OLE2DISP)   ok   0999517642299539456
      last four digits are 9456   ok   9456

That is the sequence `OLE2DISP.DLL` 2.3.3027.1 uses to detect a
reduced-precision FPU. On Daum's `double` core it returns ...9600, the DLL pops
an extra stack entry, and DOSBox aborts on the stack underflow -- which is why
Windows 3.1 OLE applications fail on Apple Silicon and work on Intel.

## FPREM is not FPREM1

The two instructions differ only in how the quotient is rounded before the
multiply-subtract — FPREM truncates toward zero, FPREM1 rounds to nearest even
— and `5 rem 3` is the smallest case that separates them:

    FPREM  5,3 = 5 - 1*3 =  2
    FPREM1 5,3 = 5 - 2*3 = -1

C's `fmod()` is specified with truncation and Watcom/Borland implement it as a
FPREM loop, so a core that aliases the two makes `fmod(5.0, 3.0)` return `-1`.
This file pinned that in both directions: aliasing either instrument to the
other fails two assertions. A test that only named FPREM's expected value would
still pass if FPREM1 were later made to alias *it*.

C2 is pinned too. Bochs' kernel removes at most 63 bits of exponent per
execution and reports whether it finished; guest code loops until C2 clears.
DOSBox's `double` cores always cleared it, which was truthful for them and
would silently claim a partial result as complete here.

| mutation | caught |
|---|---|
| FPREM aliases FPREM1 | yes — 2 failures |
| FPREM1 aliases FPREM | yes — 2 failures |
| C2 hardcoded clear (the old behaviour) | yes — 1 failure |
| quotient bits C1 and C3 swapped | yes — 2 failures |

## Exception masks change the answer

`softfloat_exceptionMasks` was hardcoded to 0, which declares every exception
unmasked. That is not bookkeeping — SoftFloat consults the masks while
rounding. An unmasked overflow takes the x87 wrap branch in
`s_roundPackToExtF80.cc` (`exp -= 0x6000`, the 24576 bias adjustment a trap
handler is meant to unpick); a masked one returns infinity. DOS boots with
`CW=0x37F`, all six masked, so every overflow was producing a wrapped finite
number where the guest expected `+INF`.

The CW mask bits map 1:1 onto the softfloat flags — `IM DM ZM OM UM PM` against
`invalid denormal divbyzero overflow underflow inexact`, `0x01`..`0x20` in the
same order — so the fix is `fpu.cw & 0x3f`.

`ES` (0x80) and `B` (0x8000) are set too, sticky until `FCLEX`/`FINIT`. Daum's
x86 core got both from the host FPU's own status word; the portable core never
set them, so this is another place the two slices disagreed.

**Traps are still not delivered.** Real hardware asserts FERR#, the PC routes it
to IRQ13 and INT 75h, and a handler runs. DOSBox has no `#MF` and no IRQ13 FPU
path, so the result is written and execution continues. Suppressing the write —
what the hardware does — would strand the guest in a state only the handler we
cannot call could clear. Polling code (`fdiv` / `fnstsw ax` / `test ah,0x80`),
the common DOS idiom, now reads the truth; an installed INT 75h handler still
will not fire.

| mutation | caught |
|---|---|
| masks hardcoded to 0 (the bug) | yes — 1 failure |
| masks hardcoded to all-masked | yes — 1 failure |
| ES never set | yes — 2 failures |
| ES set on any exception, masked or not | yes — 3 failures |
| B not set alongside ES | yes — 1 failure |
| FCLEX leaves ES behind | yes — 1 failure |

## The test is checked for discrimination

`test_original_core.cc` runs the identical sequence against Daum's stock
`fpu_instructions.h` and asserts it FAILS. A test that cannot fail proves
nothing, so this is part of the suite rather than a footnote:

    original double core -> 0999517642299539600   FAIL (expected)
    DISCRIMINATING: fails on the old core, passes on the new one.

## The dynamic core had its own FPU

Patching `src/fpu/fpu.cpp` to include this header fixed `core=normal` and left
`core=dynamic` alone, for the entire life of the build. `dyn_fpu.h` — reached
from `core_dynrec.cpp` via `decoder.h` — carried its own copy of the same
selection:

    #if C_FPU_X86
    #include "../../fpu/fpu_instructions_x86.h"
    #else
    #include "../../fpu/fpu_instructions.h"
    #endif

The entry points in both headers are `static`, so each translation unit gets its
own set, and `dyn_fpu.h` emitted calls to *its* copy. The default core of the
shipped build was therefore running Daum's 53-bit `double` FPU.

Nothing said so. `daum_audit_features()` printed
`FPU core = SoftFloat-3e (80-bit, identical on every slice)` on every build,
which was a true statement about `fpu.cpp` and a false one about the binary.
The host harness here could not have caught it either: it compiles the header
directly, so it was always testing the core the interpreter used.

What caught it was running the same guest test under both cores and comparing:

    core=normal   00999517642299539456 | 2 -1 | I0
    core=dynamic  00999517642299539600 | 2 -1 | F0

`...9600` is this file's own recorded answer for the double core, and `F0` is a
masked overflow returning a finite number, which only happens where nothing
reads the control word's mask bits. Two independent signatures of the same
cause, in a check that had existed for about an hour.

The lesson that generalises: **a host harness over a header tests the header, not
the build.** It cannot see a second consumer. The comparison that found this
runs the real binary twice and diffs it against itself, and that is the shape to
reach for when asking "is this actually what ships?".


## Testing the coverage histogram

`DOSBOX_FPU_PROFILE=<path>` makes this suite write the same histogram the
emulator writes. Run it **without** `DOSBOX_FPU_PROFILE_EVERY`:

    DOSBOX_FPU_PROFILE=/tmp/cov.txt ./test && cat /tmp/cov.txt

Setting `EVERY=1` forces a dump per operation and hides the case that actually
broke: the default period is 200,000 ops, so a short workload only ever gets a
file because of the `atexit` dump. Validating with `EVERY=1` tested a
configuration nothing ships with, and the defect reached a build.

The anomaly counts double as a cross-check on the suite itself — it is built to
raise exactly `IE=3 ZE=2 OE=2 SF=1 ES=2`, from the two QNaN compares, both
divide-by-zeros, both overflows and the empty-operand stack fault.
