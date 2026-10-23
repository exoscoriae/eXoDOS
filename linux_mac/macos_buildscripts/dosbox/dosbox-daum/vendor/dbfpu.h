/* dbfpu.h -- FPU coverage and anomaly histogram for DOSBox Daum.
 *
 * WHAT THIS ANSWERS
 * -----------------
 * "Is the FPU working?" cannot be answered by running a game.  A game tells you
 * nothing was so wrong that it crashed.  What it can tell you -- and what
 * nothing here measured before -- is WHICH FPU paths a workload actually
 * executes.  That matters because every fix is untested by any workload that
 * never reaches it:
 *
 *     $ DOSBOX_FPU_PROFILE=/tmp/fpu.txt dosbox-daum -conf fury3.conf
 *     $ cat /tmp/fpu.txt
 *     [fpu] ops=48213914  anomalies: IE=0 SF=0 ES=0 ...
 *       FPATAN        1240113
 *       FPREM               0        <-- this workload does not test FPREM
 *       ...
 *
 * A zero is as informative as a large number.  "Fury3 ran clean" plus
 * "FPATAN = 0" would mean the FPATAN fix had not been exercised at all.
 *
 * WHERE THE COUNTERS LIVE
 * -----------------------
 * In fpu_instructions_softfloat.h, at the entry points themselves -- NOT in
 * fpu.cpp's FPU_ESCn_* dispatchers.  Under core=dynamic, core_dynrec/dyn_fpu.h
 * decodes the ESC opcodes itself and calls the FPU_* functions directly, so the
 * dispatchers are bypassed entirely and would have counted zero for the default
 * core.  Instrumenting the shared header covers both cores from one place --
 * which only became possible once both of them actually included it (see the
 * dyn_fpu.h fix in audit/FINDINGS.md).
 *
 * The exception counters need only ONE hook, in SF_flags(), because every
 * arithmetic operation funnels its softfloat status through it.
 *
 * LINKAGE
 * -------
 * `inline`, not `static inline`, with the state in a function-local static --
 * the same shape dbprof.h uses and for the same reason.  A `static inline`
 * accessor gives every translation unit its own counters, and since fpu.cpp and
 * core_dynrec.cpp both include this, the report would silently show one core's
 * numbers.  That exact bug has already been shipped once in this project.
 *
 * COST WHEN OFF
 * -------------
 * One predictable-branch test per instrumented op against a cached int.  The
 * env is read once.  Verified inert by verify-bundle.sh rather than asserted.
 */
#ifndef DOSBOX_DBFPU_H
#define DOSBOX_DBFPU_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The ops worth naming: every entry point this audit repaired or added tests
 * for, plus the transcendentals and the common arithmetic that establishes a
 * baseline.  Deliberately not all 69 -- a histogram nobody reads is not a
 * measurement. */
enum DBFpuOp {
	DBF_FADD, DBF_FSUB, DBF_FMUL, DBF_FDIV, DBF_FSQRT,
	DBF_FPATAN,            /* operand order was wrong until this audit */
	DBF_FPREM, DBF_FPREM1, /* aliased to each other before that        */
	DBF_FCOM, DBF_FUCOM,   /* signalling vs quiet compare              */
	DBF_FXAM, DBF_FSCALE, DBF_FXTRACT,
	DBF_FBLD, DBF_FBST,    /* the OLE2DISP.DLL packed-BCD path         */
	DBF_FLD_I64, DBF_FST_I64,
	DBF_F2XM1, DBF_FYL2X, DBF_FYL2XP1,
	DBF_FSIN, DBF_FCOS, DBF_FPTAN, DBF_FSINCOS,
	DBF_FLDCW, DBF_FCLEX, DBF_FINIT,
	DBF_N
};

static const char * const dbfpu_op_name[DBF_N] = {
	"FADD","FSUB","FMUL","FDIV","FSQRT",
	"FPATAN","FPREM","FPREM1","FCOM","FUCOM",
	"FXAM","FSCALE","FXTRACT","FBLD","FBST",
	"FILD64","FIST64",
	"F2XM1","FYL2X","FYL2XP1",
	"FSIN","FCOS","FPTAN","FSINCOS",
	"FLDCW","FCLEX","FINIT"
};

/* Anomalies.  These are the ones that mean something went wrong in the guest's
 * arithmetic, as opposed to the guest merely doing arithmetic. */
enum DBFpuAnom {
	DBA_IE,        /* invalid operation                     */
	DBA_DE,        /* denormal operand                      */
	DBA_ZE,        /* divide by zero                        */
	DBA_OE,        /* overflow                              */
	DBA_UE,        /* underflow                             */
	DBA_PE,        /* precision (inexact) -- normal, noisy   */
	DBA_SF,        /* stack fault: empty-register operand   */
	DBA_ES,        /* unmasked exception raised the summary */
	DBA_N
};
static const char * const dbfpu_anom_name[DBA_N] = {
	"IE","DE","ZE","OE","UE","PE","SF","ES"
};

struct DBFpuState {
	int inited;
	int on;
	char path[1024];
	unsigned long long op[DBF_N];
	unsigned long long anom[DBA_N];
	unsigned long long total;
	unsigned long long since_dump;
	unsigned long long every;      /* op threshold between dumps  */
	long               last_dump_t;/* wall second of the last dump */
	int                atexit_set;
};

inline void dbfpu_dump(void);

inline DBFpuState &dbfpu(void)
{
	static DBFpuState s;
	if (!s.inited) {
		s.inited = 1;
		const char *e = getenv("DOSBOX_FPU_PROFILE");
		s.on = (e && *e) ? 1 : 0;
		if (s.on) {
			strncpy(s.path, e, sizeof(s.path) - 1);
			s.path[sizeof(s.path) - 1] = 0;
			const char *n = getenv("DOSBOX_FPU_PROFILE_EVERY");
			s.every = (n && *n) ? strtoull(n, NULL, 10) : 200000ULL;
			/* A dump at exit is what makes SHORT runs work at all.  Without
			 * it the file appears only once the op threshold is crossed, so
			 * a workload doing a few hundred FPU operations -- fputest.com,
			 * for one -- produced no file whatsoever and looked exactly like
			 * a hook that was never wired up.  Periodic dumping alone covers
			 * the long-running case; this covers the rest. */
			if (!s.atexit_set) { s.atexit_set = 1; atexit(dbfpu_dump); }
		}
	}
	return s;
}

/* Rewrite the file from scratch each time rather than appending.
 *
 * A histogram cannot be written incrementally, and DOSBox is usually killed
 * rather than exited -- the openglhq probe learned that the hard way.  So the
 * file is truncated and rewritten periodically, and a killed run still leaves
 * the last complete snapshot instead of a half-line. */
inline void dbfpu_dump(void)
{
	DBFpuState &s = dbfpu();
	if (!s.on) return;
	FILE *f = fopen(s.path, "w");
	if (!f) return;

	fprintf(f, "[fpu] ops=%llu\n", s.total);

	fprintf(f, "[fpu] anomalies:");
	for (int i = 0; i < DBA_N; i++)
		fprintf(f, " %s=%llu", dbfpu_anom_name[i], s.anom[i]);
	fprintf(f, "\n");
	fprintf(f, "[fpu]   IE/SF non-zero means the guest hit an invalid operation or an\n"
	           "[fpu]   empty-register operand.  PE is ordinary rounding and is expected\n"
	           "[fpu]   to be large.  ES non-zero means an UNMASKED exception fired.\n");

	fprintf(f, "[fpu] coverage (0 = this workload never executed it):\n");
	for (int i = 0; i < DBF_N; i++)
		fprintf(f, "  %-10s %14llu%s\n", dbfpu_op_name[i], s.op[i],
		        s.op[i] ? "" : "   <-- not exercised");
	fclose(f);
}

inline void dbfpu_hit(int which)
{
	DBFpuState &s = dbfpu();
	if (!s.on) return;
	s.op[which]++;
	s.total++;
	/* Throttled two ways.  The op counter keeps the clock call off the hot
	 * path; the clock keeps a game doing millions of ops a second from
	 * rewriting the file hundreds of times a second. */
	if (s.every && ++s.since_dump >= s.every) {
		s.since_dump = 0;
		long now = (long)time(NULL);
		if (now != s.last_dump_t) { s.last_dump_t = now; dbfpu_dump(); }
	}
}

inline void dbfpu_anomaly(int which)
{
	DBFpuState &s = dbfpu();
	if (!s.on) return;
	s.anom[which]++;
}

/* One test against a cached int when off. */
#define DBFPU_HIT(op)   do { if (dbfpu().on) dbfpu_hit(op); } while (0)
#define DBFPU_ANOM(a)   do { if (dbfpu().on) dbfpu_anomaly(a); } while (0)

#endif /* DOSBOX_DBFPU_H */
