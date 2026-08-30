# darwin-server-runtime

[![Swift CI](https://github.com/aditeya08varma/darwin-server-runtime/actions/workflows/swift.yml/badge.svg)](https://github.com/aditeya08varma/darwin-server-runtime/actions/workflows/swift.yml)

A native, Darwin-only process isolation runtime for macOS: a background
daemon (`darwin-runtimed`, managed by `launchd`) and a CLI (`darwin-run`)
that pulls a signed bundle, verifies and unpacks it, and runs it in a
sandboxed, resource-limited child process.

**Why:** Docker Desktop on macOS doesn't run containers natively — it
boots a hidden Linux VM underneath, which costs real idle RAM, CPU, and
cold-start latency. This project builds isolation directly on Darwin's
own primitives instead — `posix_spawn`, the `sandbox-exec` Seatbelt
mechanism, `launchd`, and Mach kernel telemetry — no VM involved.

## Quick example

```bash
# Package and sign a workload (scripts/sign-bundle.swift is a dev
# convenience - a fresh throwaway keypair each run, not real key
# management):
tar -czf my-app.tar.gz -C my-app-directory .
swift scripts/sign-bundle.swift my-app.tar.gz
# → writes my-app.tar.gz.manifest.json and verify-key.pub

darwin-run pull my-app.tar.gz --verify-key verify-key.pub
# → pulled bundle 30DA648C-..., unpacked to ~/Library/Application Support/darwin-runtime/jobs/30DA648C-.../rootfs

# Flags for darwin-run itself go BEFORE the rootfs path - anything after
# the binary path is passed through to the job, not parsed as a flag.
darwin-run exec --cpu-limit 60 "<rootfs path from above>" /server
# → job started: 56ACE166-...

darwin-run status 56ACE166-...
# → job 56ACE166-...: running

darwin-run stats 56ACE166-... --stream-otel http://localhost:4318/v1/metrics
# → streaming stats for job 56ACE166-... to http://localhost:4318/v1/metrics

darwin-run stop 56ACE166-...
# → stop signal sent to job 56ACE166-...
```

Every command above has actually been run against a real signed bundle
during development — see the Stage 3 and Stage 4 notes below.

## Architecture

```
                        darwin-run (CLI)
                              |
                  Unix domain socket (JSON IPC)
                              |
                     darwin-runtimed (daemon, launchd-managed)
              ---------------------------------------------
              |            |              |               |
        RuntimeCore    ImageStore     Isolation       Telemetry
       (shared types)  (unpack +      (Seatbelt /     (Mach metrics,
                        verify)        POSIX jail)      OTel export)
                         |     |
                CSystemBridge  CArchive
              (our own C glue, (libarchive systemLibrary
               Mach headers)    target, Homebrew-backed)
```

## Building

```bash
swift build
swift test
```

## Requirements

- macOS 13 or later, Apple Silicon (some paths in `Package.swift` and the
  `CArchive` module map assume the standard `/opt/homebrew` Homebrew prefix)
- Full Xcode installed, not just the Command Line Tools (`swift test`
  needs `XCTest.framework`, which only ships inside Xcode.app — see
  `DEBUGGING_LOG.md` #1)
- Swift 5.9+ toolchain
- Homebrew's `libarchive`: `brew install libarchive`

## Status

Built stage by stage. Each entry below is a one-line summary; full detail
and the debugging story behind each finding lives in `DEBUGGING_LOG.md`.

**Stage 0 — Bootstrap** ✅
Package layout, CI, and a proof that Swift↔C interop works before any
real logic is written.

**Stage 1 — Daemon & IPC** ✅
Shared `IPCMessage` wire protocol, a real Unix-socket server in the
daemon, `darwin-run ping`/`status`, and a `launchd` plist proven to
survive a real kill-and-respawn.

**Stage 2 — Image unpacking & verification** ✅
`libarchive` wired in for real tarball extraction with a path-traversal
guard; `CryptoKit`-based Ed25519/SHA-256 bundle verification; `darwin-run
pull` wired end to end against a real signed bundle.

**Stage 3 — Process execution & sandboxing** ✅
Two isolation backends — a real, kernel-enforced Seatbelt sandbox
(`sandbox-exec` with a hand-tuned SBPL profile) and a POSIX fallback —
plus a `ProcessSupervisor` that owns job lifecycle, log capture, and a
proven `SIGTERM`→`SIGKILL` escalation. `pull → exec → status → stop`
verified live end to end, including two real bugs caught only by that
live run (a path-canonicalization mismatch, and lost file permissions on
extraction — see `DEBUGGING_LOG.md` #10 and #11).

**Stage 4 — Telemetry & OpenTelemetry exporter** ✅ done

- **The core assumption behind this whole stage was backwards.**
  `task_for_pid` does not work just because the daemon spawned a process —
  the *target binary itself* must be signed with `get-task-allow`, found
  by testing several variations directly rather than trusting the first
  one that happened to work (root vs. entitled caller vs. entitled
  target; a compiled binary vs. a shebang script). `JobSigner` now
  ad-hoc signs each job's resolved binary right before spawn. Only works
  for compiled binaries, not scripts, since the kernel executes the
  named interpreter as the real process image, not the script text. See
  `DEBUGGING_LOG.md` #12 and #13.
- **`MachMetricsSampler`** reads real Mach `task_info` data - pure Swift
  via `import Darwin`, no C bridging needed, since these are standard SDK
  APIs unlike `libarchive`. One field was quietly wrong: `resident_size`
  (the obvious-looking choice) reported under 1MB for a job that had
  allocated and touched 15MB, consistently, regardless of sandboxing -
  `phys_footprint`, Apple's actual recommended replacement, correctly
  reported ~15.9MB once switched. An earlier unit test with a loose
  "greater than 5MB" threshold had not caught this; only the full live
  `pull → exec → stats` run, checked against a number computed by hand,
  did. See `DEBUGGING_LOG.md` #15.
- **`MetricsRingBuffer`** is a bounded, actor-guarded queue between the
  sampler and the exporter - deliberately *not* called "lock-free" (a
  true lock-free SPSC ring buffer needs `ManagedBuffer` and manual
  atomics, more than this project's sampling rate needs), proven safe
  under 100 genuinely concurrent appends with zero loss or corruption.
- **`OTelExporter`** batches samples into OTLP/HTTP+JSON and POSTs to a
  collector - port 4318 (OTLP/HTTP), not 4317 (OTLP/gRPC) as the original
  `--stream-otel` sketch implied, since gRPC needs the `grpc-swift`
  dependency. Verified against a real local HTTP server capturing the
  actual wire-level request (Docker was installed but not running, so
  this proves genuine POST/JSON behavior, not full collector-side OTLP
  spec compliance against a real collector).
- **`StatsStreamer`** connects all three into a real periodic loop -
  sample, buffer, batch-export every 5 samples - wired to `darwin-run
  stats`, and gives up cleanly (logged once, not spammed) after 3
  consecutive sampling failures, covering the script-binary case above.
  Verified fully live: a real compiled server bundle, pulled and exec'd,
  streamed multiple real OTLP batches to a local collector over several
  seconds, with real, correct, independently-verifiable memory numbers.

## Deliberate departures from a "standard container runtime"

Honest tradeoffs, not oversights:

- **Sandboxing shells out to `sandbox-exec`** rather than calling the
  private `sandbox_init()` API in-process, which fights Swift's runtime.
  Still genuinely Seatbelt-based isolation, just through a usable entry
  point.
- **Telemetry only covers genuinely compiled job binaries, and each one
  gets ad-hoc signed at spawn time.** The original assumption — that a
  process could sample its own spawned children's Mach task without
  extra work — was tested directly and found to be backwards: the
  *target* binary must itself carry the `get-task-allow` entitlement, not
  the daemon watching it. `JobSigner` signs each job's binary right
  before it runs. This doesn't extend to shebang scripts, since the
  kernel executes the named interpreter (e.g. `/bin/sh`) as the real
  process, not the script text, and re-signing a system interpreter isn't
  something this project does. See `DEBUGGING_LOG.md` #12 and #13.
- **CPU limits are real and kernel-enforced; memory limits are not
  enforced at all.** Tested three independent ways — all three refuse to
  lower memory-related rlimits on macOS. `--memory-limit` is accepted and
  logged as unenforceable rather than silently doing nothing. Real
  enforcement would need active Mach-based monitoring — Stage 4
  territory. See `DEBUGGING_LOG.md` #9.
- **Performance numbers are measured, not asserted.** Cold-start latency
  and memory overhead live as reproducible scripts in `benchmarks/`,
  reported here only once actually measured.
