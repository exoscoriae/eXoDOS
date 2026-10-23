/*
 *  dbprof.h -- opt-in main-loop profiler for DOSBox SVN Daum.
 *
 *  Written for one specific question: with output=opengl AND cycles=max the
 *  emulation speed collapses, while either setting on its own is fine.  The
 *  usual suspects are already ruled out (PBO path, vsync, dynrec/W^X, Voodoo
 *  GL, frame count, CPU saturation, per-frame render cost), so the next thing
 *  to do is stop guessing and measure where the wall clock actually goes.
 *
 *  Two numbers do most of the work here:
 *
 *    wall  -- elapsed real time for one pass of Normal_Loop
 *    cpu   -- CLOCK_THREAD_CPUTIME_ID delta over the same pass
 *
 *  wall >> cpu means the emulator thread was BLOCKED: a GL swap waiting on the
 *  window server, a context lock, a sleep.  wall ~= cpu means the thread was
 *  running the whole time and simply did less work per second, which points at
 *  E-core demotion / QoS, cache thrash, or genuine extra work.  Those two
 *  hypotheses need completely different fixes, and no amount of frame-time
 *  measurement separates them.
 *
 *  Everything is compiled in but gated at run time on $DOSBOX_PROF, so a
 *  shipped bundle behaves exactly as before and a suspect run needs no rebuild.
 *
 *      DOSBOX_PROF=1                  enable
 *      DOSBOX_PROF_LOG=/path/file     write there instead of stderr
 *      DOSBOX_PROF_STALL_MS=8         report any single pass at least this long
 *                                     (0 disables the per-stall lines)
 *      DOSBOX_PROF_EVERY_MS=2000      summary period (0 disables summaries)
 *      DOSBOX_PROF_MAXLINES=200       per-summary-window line cap, so the
 *                                     profiler cannot itself become the stall
 *
 *  Phase accounting.  DBP_HW..DBP_DELAY are top level and mutually exclusive:
 *  they sum to the pass wall time, less whatever is unaccounted.  DBP_MAP..
 *  DBP_TITLE are *nested* inside those (the VGA render path runs from a PIC
 *  event, which runs inside the CPU phase), so they are reported separately as
 *  "of which" rather than added in.  Double counting them would be the easiest
 *  way to draw a confidently wrong conclusion.
 *
 *  GPLv2, same as DOSBox.
 */

#ifndef DOSBOX_DBPROF_H
#define DOSBOX_DBPROF_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Top level: mutually exclusive, sum to the pass wall time. */
enum {
	DBP_HW = 0,     /* run_hw()                                */
	DBP_PIC,        /* PIC_RunQueue()                          */
	DBP_CPU,        /* (*cpudecoder)()                         */
	DBP_EVENTS,     /* GFX_Events() -- SDL_PollEvent           */
	DBP_TICK,       /* TIMER_AddTick()                         */
	DBP_DELAY,      /* SDL_Delay(1) in the increaseticks idle  */
	DBP_NTOP,
	/* Nested inside the above -- reported, never summed. */
	DBP_MAP = DBP_NTOP, /* glMapBufferARB   (PBO acquire)      */
	DBP_TEXUP,      /* glTexSubImage2D / glUnmapBufferARB      */
	DBP_DRAW,       /* glCallList                              */
	DBP_SWAP,       /* SDL_GL_SwapBuffers                      */
	DBP_TITLE,      /* SDL_WM_SetCaption                       */
	DBP_N
};

struct DBProfState {
	int                inited;
	int                on;
	FILE              *out;

	unsigned long long ns[DBP_N];        /* current pass   */
	unsigned long      n[DBP_N];
	unsigned long long tot_ns[DBP_N];    /* current window */
	unsigned long      tot_n[DBP_N];

	unsigned long long pass_wall0, pass_cpu0, pass_cyc0;
	unsigned long long win_t0, win_wall, win_cpu, win_cyc;
	unsigned long      win_passes, win_stalls, win_busy, win_lines;

	unsigned long long stall_ns, window_ns;
	unsigned long      max_lines;

	unsigned long      adj_updates, adj_held, adj_panics;
	long long          adj_last_cmax_from, adj_last_cmax_to;
	long long          adj_last_ratio, adj_last_sched, adj_last_done;
};

static const char * const dbprof_phase_name[DBP_N] = {
	"hw", "pic", "cpu", "ev", "tick", "delay",
	"map", "texup", "draw", "swap", "title"
};

/* ---------------------------------------------------------------- clocks */

static inline unsigned long long dbprof_wall_ns(void)
{
#if defined(__APPLE__)
	/* commpage read, no syscall */
	return (unsigned long long)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ULL +
	       (unsigned long long)ts.tv_nsec;
#endif
}

/* Costs roughly a microsecond on Darwin (thread_info trap), so this is only
 * ever called at pass boundaries -- never inside a phase probe. */
static inline unsigned long long dbprof_cpu_ns(void)
{
#if defined(__APPLE__)
	return (unsigned long long)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
#else
	struct timespec ts;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ULL +
	       (unsigned long long)ts.tv_nsec;
#endif
}

/* ----------------------------------------------------------------- state */

static inline unsigned long long dbprof_env_ms(const char *name,
                                               unsigned long long dflt_ms)
{
	const char *v = getenv(name);
	if (!v || !*v) return dflt_ms * 1000000ULL;
	return (unsigned long long)strtoull(v, NULL, 10) * 1000000ULL;
}

/* MUST be `inline`, never `static inline`.
 *
 * The state lives in a function-local static, which the standard guarantees is
 * a single shared object across every translation unit *provided the enclosing
 * function has external linkage*.  Adding `static` gives the function internal
 * linkage, and then each .cpp silently gets its own private copy of the whole
 * profiler: dosbox.cpp accumulates into one, sdlmain.cpp into another, and only
 * the first is ever printed.  The failure mode is not a crash or a warning --
 * it is a plausible-looking report with every sdlmain-side counter reading
 * exactly zero, which reads as a finding rather than a bug.  It cost one
 * wrong conclusion already ("the run recorded no GL swaps at all").
 *
 * An inline variable would be tidier but needs C++17, and this build does not
 * set -std=.  verify-bundle.sh guards the regression by asserting a profiled
 * run prints exactly one "[prof] enabled" banner -- two means the state split
 * again. */
inline DBProfState &dbprof(void)
{
	static DBProfState p;
	if (!p.inited) {
		const char *e;
		p.inited = 1;
		e = getenv("DOSBOX_PROF");
		p.on = (e && *e && *e != '0') ? 1 : 0;
		if (!p.on) return p;

		p.out = stderr;
		e = getenv("DOSBOX_PROF_LOG");
		if (e && *e) {
			FILE *f = fopen(e, "w");
			if (f) { p.out = f; setvbuf(f, NULL, _IOLBF, 0); }
		}
		p.stall_ns  = dbprof_env_ms("DOSBOX_PROF_STALL_MS", 8);
		p.window_ns = dbprof_env_ms("DOSBOX_PROF_EVERY_MS", 2000);
		e = getenv("DOSBOX_PROF_MAXLINES");
		p.max_lines = (e && *e) ? strtoul(e, NULL, 10) : 200;
		p.win_t0 = dbprof_wall_ns();

		fprintf(p.out,
		        "[prof] enabled  stall>=%.1fms  summary every %.1fs  "
		        "(wall>>cpu means blocked, wall~=cpu means slow)\n",
		        p.stall_ns / 1e6, p.window_ns / 1e9);
	}
	return p;
}

static inline int dbprof_on(void) { return dbprof().on; }

/* ---------------------------------------------------------------- probes */

static inline unsigned long long dbprof_t0(void)
{
	return dbprof().on ? dbprof_wall_ns() : 0ULL;
}

static inline void dbprof_add(int phase, unsigned long long t0)
{
	DBProfState &p = dbprof();
	if (!p.on || !t0) return;
	p.ns[phase] += dbprof_wall_ns() - t0;
	p.n[phase]++;
}

/* Wrap a single statement.  Commas are safe as long as they sit inside
 * parentheses, which is true of every call site this build patches. */
#define DBPROF_TIME(phase, stmt)                       \
	do {                                               \
		unsigned long long dbp__t0 = dbprof_t0();      \
		stmt;                                          \
		dbprof_add(phase, dbp__t0);                    \
	} while (0)

/* ------------------------------------------------------------- reporting */

static inline int dbprof_line_ok(DBProfState &p)
{
	if (p.max_lines && p.win_lines >= p.max_lines) return 0;
	p.win_lines++;
	return 1;
}

static inline void dbprof_phase_line(DBProfState &p,
                                     const unsigned long long *ns,
                                     const unsigned long *n,
                                     unsigned long long wall)
{
	unsigned long long top = 0;
	int i;
	char buf[512];
	int off = 0;

	for (i = 0; i < DBP_NTOP; i++) top += ns[i];

	for (i = 0; i < DBP_NTOP && off < (int)sizeof(buf) - 40; i++)
		off += snprintf(buf + off, sizeof(buf) - off, " %s %.2f",
		                dbprof_phase_name[i], ns[i] / 1e6);
	off += snprintf(buf + off, sizeof(buf) - off, " | unacct %.2f",
	                wall > top ? (wall - top) / 1e6 : 0.0);
	fprintf(p.out, "[prof]       %s\n", buf);

	off = 0;
	for (i = DBP_NTOP; i < DBP_N && off < (int)sizeof(buf) - 48; i++)
		off += snprintf(buf + off, sizeof(buf) - off, " %s %.2f/%lu",
		                dbprof_phase_name[i], ns[i] / 1e6, n[i]);
	fprintf(p.out, "[prof]       of which GL:%s\n", buf);
}

static inline void dbprof_summary(DBProfState &p, unsigned long long now)
{
	unsigned long long win = now - p.win_t0;

	fprintf(p.out,
	        "[prof] --- %.2fs  wall %.0fms  cpu %.0fms (%.0f%% on-cpu)  "
	        "passes %lu  stalls %lu  busy %lu  emulated %.2f Mcyc (%.1f Mcyc/cpu-s)\n",
	        win / 1e9, p.win_wall / 1e6, p.win_cpu / 1e6,
	        p.win_wall ? 100.0 * p.win_cpu / p.win_wall : 0.0,
	        p.win_passes, p.win_stalls, p.win_busy, p.win_cyc / 1e6,
	        p.win_cpu ? p.win_cyc * 1000.0 / p.win_cpu : 0.0);

	dbprof_phase_line(p, p.tot_ns, p.tot_n, p.win_wall);

	fprintf(p.out,
	        "[prof]       autoadjust: %lu applied, %lu held, %lu PANIC(/3)  "
	        "cmax %lld->%lld  last ratio %lld sched %lld done %lld\n",
	        p.adj_updates, p.adj_held, p.adj_panics,
	        p.adj_last_cmax_from, p.adj_last_cmax_to,
	        p.adj_last_ratio, p.adj_last_sched, p.adj_last_done);
	fflush(p.out);

	memset(p.tot_ns, 0, sizeof(p.tot_ns));
	memset(p.tot_n,  0, sizeof(p.tot_n));
	p.win_t0 = now;
	p.win_wall = p.win_cpu = p.win_cyc = 0;
	p.win_passes = p.win_stalls = p.win_busy = p.win_lines = 0;
	p.adj_updates = p.adj_held = p.adj_panics = 0;
}

/* --------------------------------------------------------------- passes */

static inline void dbprof_pass_end(unsigned long long cycles, long long cmax)
{
	DBProfState &p = dbprof();
	unsigned long long now, wall, cpu;
	int i;

	if (!p.on || !p.pass_wall0) return;

	now  = dbprof_wall_ns();
	wall = now - p.pass_wall0;
	cpu  = dbprof_cpu_ns() - p.pass_cpu0;

	p.win_wall += wall;
	p.win_cpu  += cpu;
	p.win_cyc  += cycles - p.pass_cyc0;
	p.win_passes++;
	for (i = 0; i < DBP_N; i++) { p.tot_ns[i] += p.ns[i]; p.tot_n[i] += p.n[i]; }

	if (p.stall_ns && wall >= p.stall_ns) {
		/* A long pass is not automatically a problem.  At cmax 300000 a single
		 * CPU_Cycles batch legitimately runs for tens of milliseconds, and that
		 * shows up here as wall ~= cpu -- the thread was working, not waiting.
		 * Labelling the two cases apart keeps a page of benign BUSY lines from
		 * reading as a page of stalls. */
		unsigned long long blocked = wall > cpu ? wall - cpu : 0;
		int is_stall = (blocked * 2 >= wall);
		if (is_stall) p.win_stalls++; else p.win_busy++;
		if (dbprof_line_ok(p)) {
			fprintf(p.out,
			        "[prof] %s wall %.2fms  cpu %.2fms  blocked %.2fms  "
			        "cyc %llu  cmax %lld\n",
			        is_stall ? "STALL" : "BUSY ", wall / 1e6, cpu / 1e6,
			        blocked / 1e6, cycles - p.pass_cyc0, cmax);
			dbprof_phase_line(p, p.ns, p.n, wall);
		}
	}

	if (p.window_ns && now - p.win_t0 >= p.window_ns)
		dbprof_summary(p, now);

	p.pass_wall0 = 0;
}

/* Normal_Loop has several early `return`s (callback dispatch, guest page
 * fault) that never reach the pass_end call site.  Closing any pass still open
 * here means those iterations are still measured instead of silently vanishing
 * from the totals -- and a systematically missing iteration is exactly the
 * shape of bug that makes a profiler agree with whatever you already believed. */
static inline void dbprof_pass_begin(unsigned long long cycles)
{
	DBProfState &p = dbprof();
	if (!p.on) return;
	if (p.pass_wall0) dbprof_pass_end(cycles, -1);
	memset(p.ns, 0, sizeof(p.ns));
	memset(p.n,  0, sizeof(p.n));
	p.pass_cyc0  = cycles;
	p.pass_cpu0  = dbprof_cpu_ns();
	p.pass_wall0 = dbprof_wall_ns();
}

/* ----------------------------------------------------------- autoadjust */

/* Called for every decision the cycles=max controller makes, including the
 * ones it declines to apply -- a ratio below the 1%/12% cut-offs is itself a
 * finding, because it means the controller saw the stall and threw the
 * measurement away rather than reacting to it. */
static inline void dbprof_adjust(long long sched, long long done,
                                 long long added, long long ratio,
                                 long long cmax_from, long long cmax_to,
                                 int applied)
{
	DBProfState &p = dbprof();
	if (!p.on) return;
	if (applied) p.adj_updates++; else p.adj_held++;
	p.adj_last_sched = sched;
	p.adj_last_done  = done;
	p.adj_last_ratio = ratio;
	p.adj_last_cmax_from = cmax_from;
	p.adj_last_cmax_to   = applied ? cmax_to : cmax_from;
	if (dbprof_line_ok(p))
		fprintf(p.out,
		        "[prof] adj   sched %lld done %lld added %lld ratio %lld  "
		        "cmax %lld -> %lld  %s\n",
		        sched, done, added, ratio, cmax_from, cmax_to,
		        applied ? "APPLIED" : "held (ratio below cut-off)");
}

/* --------------------------------------------------------- focus latching
 *
 * DOSBox halves the guest clock and latches CPU_SkipCycleAutoAdjust on every
 * focus-lost, and only a focus-gained clears it -- an assumption that those
 * two events arrive in pairs.  Under sdl12-compat on macOS they do not, and an
 * unpaired loss is indistinguishable after the fact from a real one.  So log
 * the raw SDL_ACTIVEEVENT mask at the moment it arrives rather than trying to
 * reconstruct the sequence from its consequences.
 */
static inline void dbprof_focus(int state, int gain, int input_focus,
                                long long cmax)
{
	DBProfState &p = dbprof();
	if (!p.on) return;
	if (dbprof_line_ok(p))
		fprintf(p.out, "[prof] focus state 0x%02x gain %d%s  cmax %lld\n",
		        (unsigned)state & 0xffu, gain,
		        input_focus ? "  INPUTFOCUS" : "", cmax);
}

/* Every transition of the latch, including the suppressed re-entries that
 * upstream would have treated as another reason to halve the clock. */
static inline void dbprof_skip(const char *what, int suppressed,
                               long long cmax_from, long long cmax_to,
                               long long sched, long long done)
{
	DBProfState &p = dbprof();
	if (!p.on) return;
	if (dbprof_line_ok(p))
		fprintf(p.out,
		        "[prof] skip  %-7s cmax %lld -> %lld  sched %lld done %lld%s\n",
		        what, cmax_from, cmax_to, sched, done,
		        suppressed ? "  (repeat -- halving suppressed)" : "");
}

/* The /3 branch: one pass took more than 15ms of wall clock while fewer than
 * 5 emulated ticks were scheduled, so the controller assumes the host cannot
 * keep up and cuts the clock by two thirds.  A handful of these in a row is a
 * collapse, and each one is caused by a single identifiable stall -- which the
 * STALL line immediately above will have attributed to a phase. */
static inline void dbprof_panic(long long added, long long sched,
                                long long cmax_from, long long cmax_to)
{
	DBProfState &p = dbprof();
	if (!p.on) return;
	p.adj_panics++;
	p.adj_last_cmax_from = cmax_from;
	p.adj_last_cmax_to   = cmax_to;
	if (dbprof_line_ok(p))
		fprintf(p.out,
		        "[prof] PANIC added %lld sched %lld  cmax %lld -> %lld  (/3)\n",
		        added, sched, cmax_from, cmax_to);
}

#endif /* DOSBOX_DBPROF_H */
