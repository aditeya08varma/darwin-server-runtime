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
# Sign and package a workload elsewhere, then:
darwin-run pull my-app.tar.gz --verify-key release.pub
# → pulled bundle 30DA648C-..., unpacked to ~/Library/Application Support/darwin-runtime/jobs/30DA648C-.../rootfs

darwin-run exec "<rootfs path from above>" /server.sh --cpu-limit 60
# → job started: 56ACE166-...

darwin-run status 56ACE166-...
# → job 56ACE166-...: running

darwin-run stop 56ACE166-...
# → stop signal sent to job 56ACE166-...
```

Every command above has actually been run against a real signed bundle
during development — see the Stage 3 notes below.

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

**Stage 4 — Telemetry & OpenTelemetry exporter** ⬜ not started
Mach `task_info` sampling of the daemon's own children, a bounded
actor-guarded ring buffer, and an OTLP/HTTP exporter behind `darwin-run
stats`.

## Deliberate departures from a "standard container runtime"

Honest tradeoffs, not oversights:

- **Sandboxing shells out to `sandbox-exec`** rather than calling the
  private `sandbox_init()` API in-process, which fights Swift's runtime.
  Still genuinely Seatbelt-based isolation, just through a usable entry
  point.
- **Telemetry will only cover processes the daemon itself spawns.**
  Sampling an arbitrary PID's Mach task needs a debugging entitlement
  this project doesn't have; spawning your own children sidesteps that.
- **CPU limits are real and kernel-enforced; memory limits are not
  enforced at all.** Tested three independent ways — all three refuse to
  lower memory-related rlimits on macOS. `--memory-limit` is accepted and
  logged as unenforceable rather than silently doing nothing. Real
  enforcement would need active Mach-based monitoring — Stage 4
  territory. See `DEBUGGING_LOG.md` #9.
- **Performance numbers are measured, not asserted.** Cold-start latency
  and memory overhead live as reproducible scripts in `benchmarks/`,
  reported here only once actually measured.
