#!/bin/bash
# Measures darwin-run exec's cold-spawn latency, sandboxed vs unsandboxed,
# using hyperfine for statistically sound timing (mean, stddev, outliers)
# instead of a single hand-timed run. Optionally compares against `docker
# run` if Docker's own daemon happens to be reachable, so the two numbers
# come from the same machine in the same sitting.
#
# This does NOT measure how fast the underlying job runs - it measures
# how long darwin-run exec takes to return once the daemon has accepted
# the job and spawned it, which is the same "time to a running job"
# question `docker run -d` answers for a container.
set -euo pipefail

if ! command -v hyperfine > /dev/null; then
    echo "hyperfine is required: brew install hyperfine"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$(mktemp -d)"
trap 'rm -rf "$DEMO_DIR"' EXIT

# A true no-op binary is used deliberately, so the measured time is only
# the daemon's spawn overhead, not any work the job itself does.
mkdir -p "$DEMO_DIR/bundle"
echo 'int main(void) { return 0; }' > "$DEMO_DIR/noop.c"
clang -O2 -o "$DEMO_DIR/bundle/noop" "$DEMO_DIR/noop.c"
chmod +x "$DEMO_DIR/bundle/noop"
tar -czf "$DEMO_DIR/noop.tar.gz" -C "$DEMO_DIR/bundle" .

echo "building release binaries (debug builds are not representative of real overhead)..."
swift build -c release --package-path "$REPO_ROOT" > /dev/null

DARWIN_RUN="$REPO_ROOT/.build/release/darwin-run"
swift "$REPO_ROOT/scripts/sign-bundle.swift" "$DEMO_DIR/noop.tar.gz" > /dev/null

if ! "$DARWIN_RUN" ping > /dev/null 2>&1; then
    echo "darwin-runtimed is not running - load it first (see USAGE.md step 3)"
    exit 1
fi

PULL_OUTPUT=$("$DARWIN_RUN" pull "$DEMO_DIR/noop.tar.gz" --verify-key "$DEMO_DIR/verify-key.pub")
ROOTFS=$(echo "$PULL_OUTPUT" | grep "unpacked to" | sed 's/unpacked to //')

echo ""
echo "=== darwin-run exec: cold-spawn latency ==="
hyperfine --warmup 5 --min-runs 50 \
    -n "Seatbelt sandboxed" "$DARWIN_RUN exec \"$ROOTFS\" /noop" \
    -n "--no-isolated" "$DARWIN_RUN exec --no-isolated \"$ROOTFS\" /noop"

if docker info > /dev/null 2>&1; then
    docker pull alpine:latest > /dev/null
    docker run -d --rm alpine:latest true > /dev/null
    echo ""
    echo "=== docker run: cold-spawn latency (Docker daemon already running) ==="
    hyperfine --warmup 3 --min-runs 30 \
        -n "docker run -d --rm alpine true" "docker run -d --rm alpine:latest true"
else
    echo ""
    echo "Docker daemon not reachable - skipping docker run comparison."
    echo "(This is itself the point: darwin-runtimed has no separate boot step to wait for.)"
fi
