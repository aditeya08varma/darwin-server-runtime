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
                              |
                        CSystemBridge
                  (libarchive, Mach headers, C interop)
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

### Stage 1 — Core daemon & IPC control plane (not started)

`RuntimeCore`'s real `IPCMessage` protocol, the `NWListener`-based Unix
socket server in `DarwinDaemon`, `OSLog`-based daemon observability, the
`darwin-run ping`/`status` round trip, and the `launchd` LaunchAgent plist.

### Stage 2 — Image unpacking & verification (not started)

libarchive bindings in `CSystemBridge`, tarball unpacking with a
path-traversal guard, and Ed25519/SHA-256 signature verification via
CryptoKit, wired up behind `darwin-run pull`.

### Stage 3 — Process execution & Darwin sandboxing (not started)

The `ProcessIsolationEngine` abstraction, a `sandbox-exec`-based Seatbelt
backend with dynamically generated SBPL profiles, a POSIX fallback backend,
and process lifecycle supervision, wired up behind `darwin-run exec`.

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
- **Memory limits are best-effort, not a hard ceiling.** macOS has no
  cgroups-style hard memory cap for arbitrary processes; `--memory-limit`
  maps to `RLIMIT_AS`, a soft constraint, not a guarantee.
- **Performance numbers are measured, not asserted.** Cold-start latency,
  memory overhead, and telemetry CPU cost are tracked as reproducible scripts
  in `benchmarks/` and reported here only once actually measured.

## Building

```bash
swift build
swift test
```

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select -p` should print a path)
- Swift 5.9+ toolchain
