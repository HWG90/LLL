# Shared Steam screenshot service

`LiveLuaLoader.capture_service` (also available through `compatibility`) is the
version-1 asynchronous game-window PNG API. Its source and candidate are under
validation; an installed build, loader acknowledgement and live screenshot are
separate acceptance checks. This does not expose native player/input access.

The existing content-addressed helper owns one capture worker at a time. WGC,
D3D readback and PNG encoding run on that worker, outside the pipe exchange
thread. The graphics DLLs load on demand. No worker, scanning or capture polling
runs while idle. Only the authenticated connected game's exact process image,
creation time and unique visible foreground window are eligible.

`service.output_directory` is `%LOCALAPPDATA%/LLL/Helldivers2/Screenshots`.
Outputs are direct PNG children of that directory, with at most 128 ASCII bytes
in the filename. Letters, digits, spaces, `_`, `-` and `.` are accepted; the first
character must be a letter, digit, `_` or `-`. Reserved DOS names, paths to other
directories, alternate streams, reparse ancestors and existing files are refused.
Publication uses a flushed, non-replacing atomic rename. The active job pins its
directory ancestors against replacement until retirement.
An owned temporary guard file keeps the output directory nonempty throughout
the job and is deleted when the worker retires.

## Caller contract

All methods use dot calls. Obtain a fresh token for each attempt:

```lua
local capture = assert(LiveLuaLoader.capture_service)
local job = assert(capture.new_job_token()) -- pure Lua; no helper I/O
local intent = {
    job_token = job,
    output_token = job .. ':png',
    output_path = capture.output_directory .. '/War Journalist-example.png',
}
-- Hide the overlay and wait for the intended clean rendered frames first.
local reply, why = capture.request(intent)
```

- `new_job_token()` returns a session-qualified, increasing token. Only the
  latest issued, unused token can start a request. State is bounded; there is no
  token-history table or 1,024-job limit. A session refuses after 2^32-1 tokens.
- `request(intent)` returns a matching record, or `nil, reason` for a confirmed
  rejection. `output_token` is an immutable caller string of 1–256 printable
  bytes. Copy the intent before using it asynchronously.
- `status(job_token, output_token)` returns a matching record or `nil, reason`
  for an unknown/stale identity. Pending native reads are limited to one every
  100 ms. The caller should query only during active capture/cleanup, using the
  unscaled application clock. Terminal queries use cached state and no I/O.
- `cancel(job_token, output_token)` returns `true, terminal_record` only when
  the worker has retired and future publication is fenced. Otherwise it returns
  `false, pending_record`; continue bounded active cleanup through status/cancel.
  A stale identity returns `false, nil, reason`.

A record contains `job_token`, `output_token`, the exact requested `output_path`
spelling, `state`, `width`, `height`, `elapsed_ms`, `reason`, `uncertain` and
`cancel_requested`. States are `pending`, `succeeded`, `failed` and `cancelled`.
Success requires a published PNG with positive client dimensions. All terminal
states require worker exit, callback/resource cleanup and retired handles.

Cancellation and publication race at one atomic decision. Cancellation that
wins prevents publication. If publication already won, cancellation can resolve
to success; it still cannot acknowledge completion until the worker has exited.
Restore the overlay on cancellation, but keep capture ownership during pending
cleanup so another request cannot overlap it.

If a transport acknowledgement is lost, a request remains `pending` and
`uncertain`; it is never reported as a confirmed rejection. Explicit bounded
status/cancel calls can recover a known native job ID. If the initial request ID
was never received, the facade refuses further captures for that session;
reconnect/restart is required to re-establish retirement. Idle calls never retry.
Loader detachment permanently closes new-job admission, including retained API
references, while status and cancellation remain available for owned cleanup.

The worker accepts fresh SDR BGRA8 client pixels only. It verifies physical
window/DWM geometry, crop, monitor, focus and process identity through the job,
and refuses unknown/HDR outputs. Its five-second budget bounds frame waiting
and cooperative phase checkpoints; it cannot preempt a Windows/WIC/D3D call.
The exchange thread remains responsive during those calls. No desktop fallback,
game-loaded DLL, input changes or game-memory access is used.

## Candidate validation, 2026-10-20

The elevated Windows build passed the 91-test Steam suite. Final focused checks
passed 12 facade tests, two assembled-loader lifecycle regressions and six
runtime tests. The native fake-worker suite passed 941 checks, including both
junction and symlink mutation refusal, full-path publication, cancellation races
and retirement. Eight repeated privilege-only cycles stayed at 84 handles;
eight full job cycles stayed at their warmed baseline of 87.
Request/status/cancel maxima were 16/0/0 ms in
that fixture; these are external helper timings, not measured game frame cost.

The private R33 candidate was installed and its new startup/helper acknowledged.
The first display inspection reported a 3840x2160, 10-bit PQ/Rec2020 output,
which this SDR worker refuses. After Windows HDR was disabled, fresh metadata
reported SDR/sRGB. One 3840x2160 PNG was published and acknowledged. The helper
then crashed on a subsequent cached-factory access. That candidate is held;
there is no public screenshot release or restoration claim.

The helper dump records an access violation at RVA `0xc3be`, in the cached
`GraphicsCaptureSession::IsSupported()` dispatch. A relinked MAP was accepted
only after its `.text`, `.pdata` and section RVAs matched the original binary.
The invalid vtable address lies inside `GraphicsCapture.dll` in the dump's
unloaded-module list. Per-worker COM teardown had left the process-static
C++/WinRT factory cache referring to unloaded code. The source fix clears that
cache before COM teardown. An elevated same-source regression passes 16 normal
and 16 exception-unwind fresh worker threads, exercising all three real capture
factory caches without opening a process/window, creating a graphics device or
session, or capturing pixels. The fixed candidate also passes all 98 Steam
tests and the 941 native job checks in an elevated build, and its package hashes
are verified. Dead transport failures now latch without reconnecting or further
pipe I/O; helper-dependent UI/maintenance retires once while loaded module
callbacks and the original shutdown callback remain available. Unconfirmed
native retirement still prevents a false detach acknowledgement.

The fixed `R33-steam-screenshots-factoryfix-candidate` is now installed, with
rollback and installed hashes verified. A fresh startup acknowledged that exact
revision and Photo Mode. Fresh display metadata reported SDR/sRGB at 3840x2160.
Two new PNGs and their `Screenshot saved` terminal acknowledgements were observed
at 18:02:55 and 18:03:01 EDT. The same helper survived both jobs, including the
second-worker boundary that crashed the previous candidate, with no new helper
crash dump observed. The user initially reported three saves and successful
camera/menu recovery while only two files were independently visible. A later,
explicit reopen/composition check published a third valid PNG at 18:10:56 EDT;
its file hash and terminal acknowledgement were verified, and the same helper
and game processes remained alive. This later capture used Pause after selecting
grain, vignette and a logo; the user confirmed smooth effects and a saved image
matching the game view. This establishes three observed SDR captures across the
button/Pause and reopen paths; it does not retroactively prove an unobserved
third capture in the earlier sequence. The earlier 120-second sample below
contains only the first two jobs. Full-feature parity and independent colorimetry
remain unqualified. The failed original candidate remains held; HDR and native
player/input access remain unqualified. There is no public screenshot release.

One elevated 120-second sample of that exact helper measured 2,250 ms CPU total
(18.75 ms CPU/s) across menu/input activity and the two captures. An 11.09-second
window containing both capture jobs accounted for 1,796.875 ms CPU, including
concurrent pipe/UI work. In the settled final 29.39 seconds, no additional CPU
time was measurable at the process counter's 15.625 ms granularity, with about
four pipe reads and writes per second. These are whole external-helper CPU
measurements, not Lua callback times, encoding-only cost or game-frame stalls.
Handle counts rose during graphics initialization/capture, then fell from the
first post-job 284 to 278 after the second job. Source review found explicit
per-job resource retirement and no concrete retention bug; aggregate counts
cannot identify the remaining handles or establish a leak-free graphics driver.

A separate elevated 45-second sample, taken before screenshot attempts with
Photo open, measured the external helper at 4.17 ms CPU/s. It measures the whole
helper during screenshot-idle operation, including input/pipe work; it is not
Lua callback, game-frame or capture-transition cost.
