#!/usr/bin/env bash
#
# Differential-check every instruction-encoding macro in vendor/risc_armv8le.h
# against a real AArch64 assembler.
#
# risc_armv8le.h is the single most important input to the arm64 slice and the
# least verified: nothing else in the build looks at what it emits beyond "DOS
# commands run", which passes on any code generator that happens not to crash.
# The macros are hand-written bit arithmetic -- `0xa9400000 + (reg1) + ((reg2)
# << 10) + ...` -- and an off-by-one in a shift produces a valid but different
# instruction, which is exactly the kind of thing that runs for months.
#
# Method: expand each macro with concrete operands, write the equivalent
# assembly text, assemble it, and compare word for word.  The assembler is the
# oracle; nothing here restates the encoding rules, so this cannot agree with
# the header by sharing its mistake.
#
# This found LDP64_IMM/STP64_IMM sign-extending a negative offset through the
# opcode field: `ldp x1,x2,[x3,#-64]` assembled as an STP.
#
# Needs an AArch64 assembler, so it does NOT run on the build machine unless
# one is installed.  On Debian/Ubuntu: apt install binutils-aarch64-linux-gnu.
# On macOS the system clang can do it:  CC=cc AS='cc -c -target arm64-apple-macos11 -x assembler'
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

HDR="../../vendor/risc_armv8le.h"
AS="${AS:-aarch64-linux-gnu-as}"
OBJDUMP="${OBJDUMP:-aarch64-linux-gnu-objdump}"

command -v "$AS"      >/dev/null || { echo "no $AS -- install binutils-aarch64-linux-gnu" >&2; exit 77; }
command -v "$OBJDUMP" >/dev/null || { echo "no $OBJDUMP" >&2; exit 77; }
[[ -f "$HDR" ]] || { echo "cannot find $HDR" >&2; exit 2; }

# Slice the macro block out of the real header at run time rather than keeping a
# copy here.  A copy would drift, and a drifted copy passing is worse than no
# check at all.
awk '/^\/\/ registers/{p=1} p' "$HDR" \
  | awk '/^static (void|INLINE)|^static.*gen_/{exit} {print}' > macros.h
[[ -s macros.h ]] || { echo "extracted no macros from $HDR -- has its layout changed?" >&2; exit 2; }

cc -w -o gen gen.c || { echo "gen.c did not compile against the header" >&2; exit 2; }
./gen > mine.txt
[[ -s mine.txt ]] || { echo "gen produced no output" >&2; exit 2; }

cut -f2 mine.txt | sed 's/^/\t/' > ref.s

# Assemble with the errors VISIBLE and fatal.
#
# This is load-bearing.  The first version of this script let `as` fail, carried
# on, and diffed against an empty ref.txt -- which printed 80 mismatches, every
# one of them formatted exactly like a real finding, with an empty "as=" field
# nobody would look at twice.  One bad line in the input read as "the entire
# code generator is wrong".  Same failure this whole audit is about: the harness
# reporting on itself.
if ! "$AS" -o ref.o ref.s 2>as.err; then
  echo "ASSEMBLER FAILED -- this is a defect in this script, not in the header." >&2
  sed 's/^/    /' as.err >&2
  exit 2
fi
"$OBJDUMP" -d ref.o | awk '/^ *[0-9a-f]+:/{print $2}' > ref.txt

n_mine="$(wc -l < mine.txt | tr -d ' ')"
n_ref="$(wc -l < ref.txt | tr -d ' ')"
if [[ "$n_mine" != "$n_ref" ]]; then
  echo "line-count mismatch: $n_mine macros vs $n_ref assembled instructions." >&2
  echo "Something in gen.c expands to more or fewer than one instruction." >&2
  exit 2
fi

bad=0
while IFS=$'\t' read -r got want text; do
  if [[ "$got" != "$want" ]]; then
    printf 'MISMATCH  header=%s  as=%s   %s\n' "$got" "$want" "$text"
    bad=$((bad+1))
  fi
done < <(paste <(cut -f1 mine.txt) ref.txt <(cut -f2 mine.txt))

if (( bad )); then
  printf '\n%d of %d encodings disagree with the assembler.\n' "$bad" "$n_mine"
  exit 1
fi
printf 'all %d encodings match %s\n' "$n_mine" "$AS"
