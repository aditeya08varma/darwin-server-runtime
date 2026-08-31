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

**New here?** [USAGE.md](USAGE.md) is a clean, step-by-step guide to
actually running this. Everything below is project design and status.

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

## Benchmarks

Measured, not asserted — run yourself with `benchmarks/cold_start.sh` and
`benchmarks/memory_footprint.sh`. Numbers below are from one real run on
an Apple M1 Pro, macOS 26.5.2, release builds (`swift build -c release`),
against Docker Desktop 27.5.1, taken back to back on the same machine in
the same sitting.

**Idle memory footprint** (`phys_footprint`, via macOS's own `footprint`
tool — the same metric `MachMetricsSampler` uses for job telemetry, not
the misleading `resident_size`/RSS numbers; see `DEBUGGING_LOG.md` #15):

| | Footprint |
|---|---|
| `darwin-runtimed`, idle, no jobs running | **~2.9 MB** |
| Docker Desktop, idle, no containers running (GUI app + helpers + the actual Linux VM host process, summed) | **~464 MB** |
| — of which just the Linux VM host process (`com.docker.virtualization`) | ~35 MB |

The ~464 MB is mostly Docker Desktop's Electron-based GUI (dashboard,
renderer, GPU helper) rather than the VM itself — but that GUI is what
actually runs on a real developer's machine using Docker Desktop, so it's
counted rather than benchmarking against a stripped-down configuration
nobody runs. Even against the VM process alone, `darwin-runtimed` is
roughly 12x smaller; against the full running app, roughly 160x.

**A fairer isolation of "VM tax" alone**, since the 35 MB Docker number
above isn't something a real Docker Desktop user can actually run without
its mandatory GUI: three tools that *are* headless-by-design were
measured too, each started fresh, measured alone, and fully stopped
before the next one started (`benchmarks/vm_runtime_comparison.sh`):

| | Idle footprint | `docker run` cold spawn | Notes |
|---|---|---|---|
| `darwin-runtimed` (this project) | **~2.9 MB** | — | no VM, no container runtime |
| Lima (bare VM, default template, no container runtime) | 2.5 GB | n/a | not a container tool — isolates raw "general-purpose Ubuntu VM" cost |
| Colima (Docker via Lima, no GUI) | ~960 MB | 130.6 ms | |
| OrbStack | ~129 MB* | 184.4 ms | |
| Docker Desktop (VM process only) | ~35 MB | 328.2 ms (full app running) | not runnable standalone — see above |
| Docker Desktop (full app) | ~464 MB | 328.2 ms | |

\* excludes one small root-owned helper process `footprint` couldn't
read without `sudo`; based on its RSS it adds roughly 10 MB.

The genuinely surprising result here: **"VM-based" doesn't mean one
fixed cost.** Lima's default general-purpose Ubuntu VM (2.5 GB) is
heavier than Docker Desktop's entire GUI-plus-VM product (464 MB),
because Docker invested in a purpose-built minimal Linux kernel for
exactly this job, while Lima's default template is a full cloud image
running systemd, journald, and other general-purpose services most of
which a container host doesn't need. Colima inherits a lighter Lima
config but is still heavier than Docker Desktop's *entire* footprint.
OrbStack, which is built specifically to be lean, comes closest to
Docker's VM-only number but still isn't smaller than it. None of the
four VM-based options get near `darwin-runtimed`'s ~2.9 MB, because it
isn't running a Linux kernel at all — every backend here still pays for
booting an operating system inside a VM, which is the actual structural
cost this project avoids, not an implementation detail specific to
Docker Desktop.

**Cold-spawn latency** (`hyperfine`, 30-75 runs after warmup, a true
no-op binary so the number reflects spawn overhead only, not job work):

| | Mean | Range |
|---|---|---|
| `darwin-run exec`, Seatbelt sandboxed | **55.4 ms** ± 26.1 ms | 23.7 – 109.5 ms |
| `darwin-run exec`, `--no-isolated` | 47.0 ms ± 24.7 ms | 23.9 – 107.8 ms |
| `docker run -d --rm alpine true` (image already pulled, daemon already running) | 328.2 ms ± 62.5 ms | 273.3 – 517.0 ms |

Seatbelt sandboxing itself costs roughly 8 ms (~18%) over the unsandboxed
path — a real, measured tax for real kernel-enforced isolation, not
nothing. Both are still ~6x faster to spawn than `docker run`, and that
Docker number assumes the daemon is *already running* — it does not
include the one-time VM boot this test measured separately at ~12
seconds from `open -a Docker` to the daemon responding, a cost
`darwin-runtimed` doesn't have at all since there's no VM to boot.

Debug builds are meaningfully worse on both axes (~4.4 MB idle footprint,
~97 ms sandboxed spawn) — the numbers above are release builds only,
since that's the fair comparison.

### Under load, not just at startup

Everything above measures the moment of starting up. It says nothing
about what happens once a job is actually working hard — this section
does, using `stress-ng` (the industry-standard synthetic load generator,
not something built for this project) as the identical workload on every
side: `darwin-runtimed` runs the real macOS build directly, and each
container tool runs a locally built, **native arm64** image (from
Alpine's own `stress-ng` package) rather than a pulled x86 image, so
virtualization overhead isn't accidentally measured as emulation
overhead. Reproduce with `benchmarks/heavy_load_comparison.sh`.

**CPU throughput** (2 workers, 20s, bogo-ops/sec real time):

| | Throughput |
|---|---|
| `darwin-runtimed`, Seatbelt sandboxed | **2899.59** |
| `darwin-runtimed`, `--no-isolated` | 2892.72 |
| Docker Desktop | 1000.98 |
| Colima | 1012.32 |
| OrbStack | 1000.39 |

Two things stand out. First, sandboxed and unsandboxed are within noise
of each other — Seatbelt's cost is at spawn/syscall time, not during raw
computation, matching the earlier cold-start finding. Second, **all
three VM-based tools land at almost exactly the same number regardless
of which product it is** — this is a real hardware/virtualization cost
on this machine, not something any one of them implemented worse than
the others. `darwin-runtimed` is ahead here specifically because it
never virtualizes anything.

**Memory throughput** (1 worker, 128MB, bogo-ops/sec real time) — the
one test that did **not** favor `darwin-runtimed`, reported honestly:

| | Throughput |
|---|---|
| Docker Desktop | **132338.77** |
| OrbStack | 126116.35 |
| `darwin-runtimed`, Seatbelt sandboxed | 119323.00 |
| Colima | 107369.04 |

A real, reproducible bug surfaced getting this number: `stress-ng`'s
`--vm` stressor does not honor its own `--timeout` on macOS — it ran
about 3x past the requested time, twice, at two different sizes,
regardless of actual memory pressure, while the identical Linux build
inside every container finished exactly on time. Confirmed as a genuine
macOS-specific quirk in `stress-ng` itself, not a memory-pressure fluke
and not anything this project's sandboxing caused — see
`DEBUGGING_LOG.md` #16 for the full story, including a second, unrelated
bug found in the same run: `stress-ng` also reports a nonsensical RSS
figure on macOS (~142 GB on a 16 GB machine) — the same category of
platform-specific memory-reporting bug this project already found and
fixed in its own telemetry, this time in someone else's tool.

**Disk I/O** (256MB, write throughput, bind-mounted to a real host
folder — the structural equivalent of how `darwin-runtimed` always
writes, since it has no bridge layer to begin with):

| | Write | Read |
|---|---|---|
| Colima | **4612 MB/s** | 14961 MB/s |
| OrbStack | 2276 MB/s | 3176 MB/s |
| `darwin-runtimed` (native, no bridge) | 1191 MB/s | 9901 MB/s |
| Docker Desktop | 1085 MB/s | 15034 MB/s |

No clean winner here either. For reference, Docker Desktop's own
*internal* container disk (not bind-mounted, i.e. not touching the host
filesystem at all) hit 5637 MB/s write — a ~5.2x drop once a real host
folder is bridged in, which is the concrete, measured cost of the
`virtiofs` bridge every VM-based tool here pays and `darwin-runtimed`
structurally cannot, since there's nothing to bridge.

**Concurrency** (20 job/container spawns launched simultaneously, total
wall time — debug build for `darwin-runtimed` here, not release, so this
gap is likely a floor, not a ceiling):

| | Time for 20 |
|---|---|
| `darwin-runtimed` | **0.39s** |
| Colima | 1.43s |
| OrbStack | 2.32s |
| Docker Desktop | 2.55s |

This is the number that actually speaks to the CI-fleet pitch — the
startup-latency advantage from the cold-start section compounds cleanly
under real concurrent load rather than disappearing.

**Honest summary**: `darwin-runtimed` wins decisively on CPU throughput
and concurrency, for real structural reasons (no virtualization layer).
It does **not** win on memory throughput or disk I/O — those came out
mixed, sometimes in Docker's or Colima's favor, and are reported as
measured rather than smoothed over. A benchmark that only shows wins
isn't a benchmark, it's marketing.

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
  and memory overhead live as reproducible scripts in `benchmarks/` — see
  the Benchmarks section above for real numbers from an actual run
  against a real running Docker Desktop, not estimates.
