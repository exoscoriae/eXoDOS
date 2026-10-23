# WineHQ bug report draft

Ready to paste into <https://bugs.winehq.org/> after a duplicate search on
`pause`, `WCMD_wait_for_input`, `console input` and `ensure_tty_input_thread`.
A general web search on 2026-07-29 found no existing report.

- **Product:** Wine
- **Component:** programs (cmd)
- **Version:** 11.0 (also present in current master — the function is unchanged)
- **Platform / OS:** All (see below — reproduced on both macOS and Linux)
- **Severity:** normal
- **Keywords:** download, patch

---

## Summary

`wine cmd /c pause` hangs forever in a Unix terminal; no keypress releases it

## Steps to reproduce

1. From a normal terminal (stdout a tty, nothing piped), run:

       wine cmd /c pause

2. `Press any key to continue...` is printed.
3. Press any key.

## Expected

The command returns, as it does on Windows and as `pause` does at an
interactive `wine cmd` prompt.

## Actual

It never returns. Pressing Return echoes a newline — that is the *terminal*
echoing locally, because the tty is still in canonical mode (`stty -a` shows
`icanon echo` while the program is hung). The process must be killed. Nothing
is logged: no `err:` or `warn:` on any channel, including `+console`.

`dir /p` hangs identically once the listing is long enough to page, since it
uses the same function.

## Not platform-specific

Reproduced identically on:

- macOS 26.5.1, Apple Silicon, x86_64 Wine under Rosetta 2, self-built wine-11.0
- Linux, Flatpak `com.retro_exo.wine`, `wine --version` reporting plain `wine-11.0`

`WCMD_wait_for_input()` is byte-identical between the `wine-11.0` tag and
current master, so this is not a regression introduced after 11.0.

## Diagnosis

`WCMD_wait_for_input()` (`programs/cmd/wcmdmain.c:607`), which `pause` and
`dir /p` both use, waits on the console input handle *before* issuing any read:

```c
if (GetConsoleMode(hIn, &oldmode))
{
    SetConsoleMode(hIn, oldmode & ~ENABLE_LINE_INPUT);
    FlushConsoleInputBuffer(hIn);
    while (return_code == ERROR_SIGNAL_PENDING)
    {
        switch (WaitForMultipleObjects(2, h, FALSE, INFINITE))   /* blocks here */
        {
        case WAIT_OBJECT_0:
            if (has_pending_char_events(hIn))                    /* never reached */
```

On a Unix console the console input object cannot become signaled until
conhost's `tty_input()` thread is reading the terminal. That thread is started
only by `ensure_tty_input_thread()` (`programs/conhost/conhost.c:1870`), which
is reached only from the six read/peek ioctls in `console_input_ioctl()`:
`IOCTL_CONDRV_READ_CONSOLE`, `READ_CONSOLE_CONTROL`, `READ_FILE`, `READ_INPUT`,
`PEEK`, `GET_INPUT_INFO`. The `main()` call site is guarded by
`!console->is_unix` and `&&` short-circuits, so it does not apply.

In this function the only call issuing one of those ioctls is
`has_pending_char_events()`, via `GetNumberOfConsoleInputEvents()` — and it is
inside the loop body, after the wait. Hence the cycle: **the wait needs input
records, records need the reader thread, and the reader thread needs a read that
only happens once the wait has already returned.**

### Trace

`WINEDEBUG=+timestamp,+console wine cmd /c pause`, cmd = 0124, conhost = 011c.
This is the complete console-side conversation up to the hang:

```
3563125.598:011c:trace:console:tty_flush "...Press any key to continue..."
3563125.599:011c:trace:console:console_input_ioctl returning mode 1f7
3563125.599:0124:trace:console:SetConsoleMode (000000000000000C,1f5)
3563125.599:011c:trace:console:console_input_ioctl set 1f5 mode
3563125.599:011c:trace:console:console_input_ioctl flush
                                        <- nothing further; hung here
```

`1f7 -> 1f5` is exactly `~ENABLE_LINE_INPUT`. Note there is only **one** `flush`:
the pre-loop `FlushConsoleInputBuffer()` at line 619. The in-loop one at line 628
never runs, confirming the wait blocks on the first iteration. No read or peek
ioctl of any kind ever reaches conhost.

While hung, both processes are alive and idle — conhost's ioctl pump is healthy,
it simply has nothing to service:

```
233 ??   Ss  0:00.12  conhost.exe --unix --width 103 --height 63 --server 0x34
235 s000 S+  0:00.11  cmd.exe /c pause
```

### Distinguishing observation

Typing `pause` at an interactive `wine cmd` prompt **works correctly**. Reading
the command line issues `IOCTL_CONDRV_READ_CONSOLE`, which starts the reader
thread; `pause` then finds it already running. Only `cmd /c pause` hangs. Same
binary, same terminal, same console.

With a temporary probe added to `ensure_tty_input_thread()`, `tty_input()` and
the server's `IOCTL_CONDRV_SETUP_INPUT` handler, the interactive case shows the
whole chain working:

```
ensure_tty_input_thread tty_input=0x9 input_thread=0x0 is_unix=1
tty_input thread running: tty_input=0x9 is_unix=1
wineserver: SETUP_INPUT handle=0x9
wineserver: unix_fd=27 isatty=1
wineserver: raw mode active, term_fd=326
SETUP_INPUT accepted for condrv handle 0x9
```

So `tcgetattr`/`tcsetattr`/`dup` all succeed and raw mode engages correctly. The
defect is purely ordering — nothing asks.

## Proposed fix

Attached: `0001-cmd-Prime-console-input-before-waiting-in-WCMD_wait_for_input.patch`

Call `has_pending_char_events()` once before the loop, which starts the reader
and lets the subsequent wait behave normally. The result is assigned to
`return_code` rather than returned so the `SetConsoleMode()` restore still runs.
Verified on macOS: `cmd /c pause`, `dir /p` and a real-world Bat2Exe launcher
(`cmd /s/c` running a batch file whose `pause` was the original symptom) all
work, and `stty -a` confirms the tty is left in canonical mode afterwards.

## Two secondary issues noticed while diagnosing

1. **The failure is completely silent.** `ensure_tty_input_thread()` returns
   `TRUE` — success — when `console->tty_input` is NULL, without starting the
   thread, and its return value is discarded at all six call sites in
   `console_input_ioctl()`. So a NULL handle and a failed `CreateThread()` are
   both indistinguishable from success. A `WARN` on either would have made this
   bug an afternoon's work rather than a week's.

2. **`server/console.c`'s `IOCTL_CONDRV_SETUP_INPUT` handler has two failure
   paths that are indistinguishable.** `tcgetattr()` failing and
   `tcsetattr()`/`dup()` failing both end in a bare `file_set_error()` and
   return the same status, so "this fd is not a terminal" and "the terminal
   refused the mode change" cannot be told apart from the client side.

## Note on the wider problem

This patch fixes cmd, but the underlying gap is more general: on a Unix console
the input object is not live until something reads it, so **any** Windows program
that waits on the console input handle before reading will deadlock. On Windows
the console input buffer is always being filled, so that is legitimate Win32
code.

Making the reader eager — dropping `!console->is_unix &&` in `conhost.c`'s
`main()` — fixes the whole class, but it would put the terminal in raw mode for
the entire life of every console process, including ones that never read input;
a backgrounded `wine tool.exe > out.txt &` would then disturb the shell. The
existing laziness looks deliberate for that reason, so this was not pursued.

The architecturally correct fix is presumably for wineserver to ask conhost to
start pumping when a thread waits on a console with no pending input, which
needs a new ioctl. That seemed a maintainers' decision rather than something to
propose blind, hence the narrower cmd-side patch above.
