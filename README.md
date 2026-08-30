# darwin-server-runtime

[![Swift CI](https://github.com/aditeya08varma/darwin-server-runtime/actions/workflows/swift.yml/badge.svg)](https://github.com/aditeya08varma/darwin-server-runtime/actions/workflows/swift.yml)

A native, Darwin-only process isolation runtime for macOS: a background
daemon (`darwin-runtimed`) managed by `launchd`, and a CLI client
(`darwin-run`) that pulls signed server image bundles, unpacks and verifies
them, and runs them in a sandboxed, resource-limited child process, with
lightweight telemetry streamed out via OpenTelemetry.

It exists to answer a specific question: on Apple Silicon, can you get
container-like isolation semantics for native macOS/Darwin workloads without
paying for Docker's Linux virtual machine? Docker Desktop on macOS does not
run containers natively on Darwin; it boots a Linux VM (QEMU/Hypervisor.framework)
underneath, which costs real idle RAM, CPU, and cold-start latency. This
project builds isolation directly on Darwin's own primitives instead:
`posix_spawn`, the `sandbox-exec` Seatbelt mechanism, `launchd`, and Mach
kernel telemetry APIs.

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

## Status

This project is being built stage by stage; each stage is described in
detail, including the specific tradeoffs made, in the sections below as it
lands.

### Stage 0 — Bootstrap (done)

- Swift Package Manager layout with all seven modules wired up as compiling
  placeholders: `RuntimeCore`, `CSystemBridge`, `ImageStore`, `Isolation`,
  `Telemetry`, and the two executables `DarwinDaemon` (`darwin-runtimed`) and
  `DarwinRuntimeCLI` (`darwin-run`).
- GitHub Actions CI (`.github/workflows/swift.yml`) running `swift build`
  and `swift test` on `macos-latest` for every push and pull request.
- A placeholder `Telemetry.bridgeIsLinked()` check that calls through
  `CSystemBridge` into a real C function, proving Swift-to-C interop works
  end to end before any real libarchive or Mach kernel code is written.

### Stage 1 — Core daemon & IPC control plane (done)

- `RuntimeCore`'s real `IPCMessage`/`IPCResponse`/`ExecConfig` wire
  protocol, newline-delimited JSON framing (`IPCFraming`, `LineFrameBuffer`),
  verified with round-trip tests including split and concatenated frames.
- An `NWListener`-based Unix domain socket server in `DarwinDaemon`,
  `OSLog`-instrumented, handling `.ping`/`.pull`/`.exec`/`.stop`/`.status`
  honestly (real work for the first two, honest "not implemented"/"no such
  job" for the rest until Stages 2 and 3 land).
- `darwin-run ping`/`status <id>` genuinely round-trip to the daemon over
  the socket, including correct handling of the case where the daemon
  isn't running at all (see `DEBUGGING_LOG.md` #4).
- A `launchd` LaunchAgent plist, verified including a real kill-and-respawn
  test proving `KeepAlive` actually restarts a crashed daemon.

### Stage 2 — Image unpacking & verification (done)

- `libarchive` wired in via a `systemLibrary` target (`CArchive`), not
  folded into `CSystemBridge` - see `DEBUGGING_LOG.md` #5 and #6 for why,
  and for a real gap that was found and then explicitly fixed (linking
  against Homebrew's `libarchive` rather than macOS's own bundled copy).
- `ImageArchive.unpack(tarball:into:)`: real tarball extraction via
  `libarchive`'s read API, with a path-traversal guard as the
  security-critical check, proven against both relative (`../`) and
  absolute path attack variants - including confirming the escaped file
  was never written to disk at all, not just that an error was thrown.
- `TrustVerifier.verify(tarball:manifest:publicKey:)`: Ed25519/SHA-256
  verification via `CryptoKit`, proven against a genuine forged-bundle
  scenario (hash rewritten to match a swapped tarball, but signed with
  the wrong key) to confirm the hash check and signature check each catch
  something the other alone would miss.
- `darwin-run pull <tarball> --verify-key <key>` wired end to end through
  the daemon socket, verified against a real signed bundle built with the
  actual `tar` command, not just a test fixture.

### Stage 3 — Process execution & Darwin sandboxing (in progress)

- `ProcessIsolationEngine` protocol plus `POSIXIsolationEngine` (path-jail
  only, no kernel enforcement past the initial check) and
  `SeatbeltIsolationEngine` (a real, dynamically generated SBPL profile
  per job, enforced continuously by the kernel). The Seatbelt backend's
  profile was worked out by iterating directly against real
  `sandbox-exec` invocations and reading exact denial reasons out of the
  unified log, not written from documentation alone - Apple doesn't
  publish an official SBPL reference.
- Real, live proof, not just passing tests by construction: a spin-loop
  process actually killed by the kernel once its CPU limit ran out
  (`SIGXCPU`), and a sandboxed script's attempt to write a file *outside*
  its rootfs actually blocked by the kernel while running - something
  `POSIXIsolationEngine` cannot stop at all, which is the real
  differentiator the two backends' tests demonstrate side by side.
- A subtle, genuinely tricky bug found and fixed along the way: `/tmp`
  (and `/var`, `/etc`) are symlinks to `/private/...` on macOS, and
  Foundation's `resolvingSymlinksInPath()` deliberately does not resolve
  them, while the kernel's own Seatbelt enforcement checks against the
  fully resolved path regardless. See `DEBUGGING_LOG.md` #10.
- Still to come: `ProcessSupervisor` (stdout/stderr capture, lifecycle,
  the `.exec`/`.stop`/`.status` IPC wiring) and `darwin-run exec` itself.

### Stage 4 — Telemetry & OpenTelemetry exporter (not started)

Mach `task_info` sampling (scoped to the daemon's own spawned children),
a bounded actor-guarded ring buffer, and an OTLP/HTTP+JSON exporter, wired
up behind `darwin-run stats`.

## A few deliberate departures from a "standard container runtime"

- **Sandboxing goes through `sandbox-exec`, not an in-process `sandbox_init()`
  call.** `sandbox_init` is a private, undocumented Apple API, and calling it
  in-process between fork and exec fights Swift's runtime. Shelling out to
  `/usr/bin/sandbox-exec` with a dynamically generated profile is still
  genuinely Seatbelt-based isolation, just via a supported entry point.
- **Telemetry only covers processes this daemon itself spawned.** Sampling
  an arbitrary process's Mach task (`task_for_pid`) is locked down by SIP/AMFI
  on modern macOS unless the caller holds a debugging entitlement. Since the
  daemon always spawns its own children, this is achievable without special
  entitlements, but it does not generalize to arbitrary external PIDs.
- **CPU limits are real; memory limits are not enforced at all yet.**
  `--cpu-limit` maps to `ulimit -t` and was confirmed genuinely
  kernel-enforced (a spin-loop process was actually killed with
  `SIGXCPU`). Memory limits are a different story: setting `RLIMIT_AS`,
  `RLIMIT_RSS`, or `RLIMIT_DATA` on macOS was tested three independent
  ways - bash's `ulimit -v`, bash's `ulimit -m`, and a raw `setrlimit()`
  syscall - and all three refuse to lower these limits at all. This isn't
  a "soft constraint," it's currently unenforceable through this
  mechanism; `--memory-limit` is accepted and logged as a warning, not
  silently pretended to work. Real per-process memory containment on
  macOS would need active monitoring via Mach's `task_info`, killing the
  process if it exceeds the limit - that's Stage 4 territory, not solved
  yet. See `DEBUGGING_LOG.md` #9.
- **Performance numbers are measured, not asserted.** Cold-start latency,
  memory overhead, and telemetry CPU cost are tracked as reproducible scripts
  in `benchmarks/` and reported here only once actually measured.

## Building

```bash
swift build
swift test
```

## Requirements

- macOS 13 or later, Apple Silicon (some paths in `Package.swift` and the
  `CArchive` module map assume the standard `/opt/homebrew` Homebrew prefix)
- Full Xcode installed, not just the Command Line Tools (`swift test`
  needs `XCTest.framework`, which only ships inside Xcode.app - see
  `DEBUGGING_LOG.md` #1)
- Swift 5.9+ toolchain
- Homebrew's `libarchive`: `brew install libarchive`
