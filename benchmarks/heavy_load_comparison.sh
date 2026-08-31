#!/bin/bash
# Everything else in benchmarks/ measures startup and idle cost. This
# script measures what happens once a job is actually working hard:
# real CPU throughput, real memory throughput, real disk I/O, and real
# concurrent-spawn behavior - none of which the cold-start/footprint
# numbers say anything about.
#
# Uses stress-ng (the industry-standard synthetic load generator) as the
# same workload on every side of the comparison: darwin-runtimed runs
# the real macOS build directly, and each container tool runs a locally
# built, native-arm64 image (built from Alpine's own stress-ng package,
# not an emulated x86 image, so virtualization overhead isn't confused
# with emulation overhead).
#
# Requires: brew install stress-ng hyperfine colima lima, and
# brew install --cask orbstack, plus Docker Desktop already installed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRESS_NG_BIN="$(command -v stress-ng || true)"
if [ -z "$STRESS_NG_BIN" ]; then
    echo "stress-ng is required: brew install stress-ng"
    exit 1
fi

echo "=========================================="
echo "darwin-runtimed"
echo "=========================================="

DEMO_DIR="$(mktemp -d)"
mkdir -p "$DEMO_DIR/bundle"
cp "$STRESS_NG_BIN" "$DEMO_DIR/bundle/"
tar -czf "$DEMO_DIR/stress.tar.gz" -C "$DEMO_DIR/bundle" .
swift "$REPO_ROOT/scripts/sign-bundle.swift" "$DEMO_DIR/stress.tar.gz" > /dev/null

DARWIN_RUN="$REPO_ROOT/.build/debug/darwin-run"
if ! "$DARWIN_RUN" ping > /dev/null 2>&1; then
    echo "darwin-runtimed is not running - load it first (see USAGE.md step 3)"
    exit 1
fi

PULL_OUTPUT=$("$DARWIN_RUN" pull "$DEMO_DIR/stress.tar.gz" --verify-key "$DEMO_DIR/verify-key.pub")
ROOTFS=$(echo "$PULL_OUTPUT" | grep "unpacked to" | sed 's/unpacked to //')

# The workload's own --timeout is trusted here for CPU and disk, but NOT
# for memory - a real, reproducible finding from developing this script
# is that stress-ng's --vm stressor does not reliably self-terminate on
# macOS (it ran 3x past its requested timeout, twice, at two different
# sizes, regardless of actual memory pressure - see DEBUGGING_LOG.md).
# So the memory test below is capped by hand instead of trusted to exit
# on its own.

echo "--- CPU (2 workers, 20s) ---"
"$DARWIN_RUN" exec "$ROOTFS" /stress-ng -- --cpu 2 --timeout 20s --metrics > /tmp/dr_cpu.log 2>&1
sleep 22
JOBID=$(grep -oE '[0-9A-F-]{36}' /tmp/dr_cpu.log)
grep "metrc.*cpu " "$HOME/Library/Application Support/darwin-runtime/job-logs/$JOBID/stdout.log" || true

echo "--- MEMORY (128MB, hand-capped at 20s wall time) ---"
"$DARWIN_RUN" exec "$ROOTFS" /stress-ng -- --vm 1 --vm-bytes 128M --timeout 15s --metrics > /tmp/dr_mem.log 2>&1
JOBID=$(grep -oE '[0-9A-F-]{36}' /tmp/dr_mem.log)
sleep 20
pkill -TERM -f "$ROOTFS/stress-ng" 2>/dev/null || true
sleep 2
grep "metrc.*vm " "$HOME/Library/Application Support/darwin-runtime/job-logs/$JOBID/stdout.log" || true

echo "--- DISK I/O (256MB, native host filesystem - no bridge exists for this tool) ---"
"$DARWIN_RUN" exec "$ROOTFS" /stress-ng -- --hdd 1 --hdd-bytes 256M --timeout 15s --metrics > /tmp/dr_io.log 2>&1
sleep 17
JOBID=$(grep -oE '[0-9A-F-]{36}' /tmp/dr_io.log)
grep "metrc.*hdd " "$HOME/Library/Application Support/darwin-runtime/job-logs/$JOBID/stdout.log" || true

echo "--- CONCURRENCY (20 simultaneous job spawns) ---"
NOOP_DIR="$(mktemp -d)"
mkdir -p "$NOOP_DIR/bundle"
echo 'int main(void) { return 0; }' > "$NOOP_DIR/noop.c"
clang -O2 -o "$NOOP_DIR/bundle/noop" "$NOOP_DIR/noop.c"
tar -czf "$NOOP_DIR/noop.tar.gz" -C "$NOOP_DIR/bundle" .
swift "$REPO_ROOT/scripts/sign-bundle.swift" "$NOOP_DIR/noop.tar.gz" > /dev/null
NOOP_PULL=$("$DARWIN_RUN" pull "$NOOP_DIR/noop.tar.gz" --verify-key "$NOOP_DIR/verify-key.pub")
NOOP_ROOTFS=$(echo "$NOOP_PULL" | grep "unpacked to" | sed 's/unpacked to //')
START=$(date +%s.%N)
for i in $(seq 1 20); do "$DARWIN_RUN" exec "$NOOP_ROOTFS" /noop > /dev/null 2>&1 & done
wait
END=$(date +%s.%N)
echo "20 concurrent spawns: $(echo "$END - $START" | bc)s"

rm -rf "$DEMO_DIR" "$NOOP_DIR"

if ! command -v docker > /dev/null; then
    exit 0
fi

# A locally built, native-arm64 image, not a pulled one - the official
# stress-ng images are x86-only, and running those under emulation would
# measure emulation overhead, not virtualization overhead. Built once,
# reused across all three container tools below (each has its own
# separate image store, so it gets rebuilt per-tool, which is fast since
# it's a tiny Alpine-based image).
IMAGE_DIR="$(mktemp -d)"
cat > "$IMAGE_DIR/Dockerfile" << 'EOF'
FROM alpine:latest
RUN apk add --no-cache stress-ng
ENTRYPOINT ["stress-ng"]
EOF

run_container_load_tests() {
    local label="$1"
    echo "--- $label: CPU (2 workers, 20s) ---"
    docker build -t local-stress-ng:arm64 "$IMAGE_DIR" > /dev/null
    docker run --rm local-stress-ng:arm64 --cpu 2 --timeout 20s --metrics 2>&1 | grep "metrc.*cpu " || true

    echo "--- $label: MEMORY (128MB, 15s) ---"
    docker run --rm local-stress-ng:arm64 --vm 1 --vm-bytes 128M --timeout 15s --metrics 2>&1 | grep "metrc.*vm " || true

    echo "--- $label: DISK I/O (256MB, bind-mounted host folder - the real structural equivalent, not the container's own internal disk) ---"
    local io_dir
    io_dir="$(mktemp -d)"
    docker run --rm -v "$io_dir:/data" -w /data local-stress-ng:arm64 --hdd 1 --hdd-bytes 256M --timeout 15s --metrics 2>&1 | grep "metrc.*hdd " || true
    rm -rf "$io_dir"

    echo "--- $label: CONCURRENCY (20 simultaneous container spawns) ---"
    docker pull alpine:latest > /dev/null 2>&1
    local start end
    start=$(date +%s.%N)
    for i in $(seq 1 20); do docker run -d --rm alpine:latest true > /dev/null 2>&1 & done
    wait
    end=$(date +%s.%N)
    echo "20 concurrent spawns: $(echo "$end - $start" | bc)s"
}

ORIGINAL_CONTEXT=$(docker context show 2>/dev/null || echo "default")

echo ""
echo "=========================================="
echo "Docker Desktop"
echo "=========================================="
open -a Docker
for i in $(seq 1 60); do docker info > /dev/null 2>&1 && break; sleep 1; done
docker context use desktop-linux > /dev/null 2>&1 || true
run_container_load_tests "Docker Desktop"
osascript -e 'quit app "Docker"' > /dev/null 2>&1 || true
sleep 3
pgrep -f "Docker Desktop|com.docker.backend" > /dev/null 2>&1 && pkill -9 -f "Docker Desktop|com.docker.backend" 2>/dev/null || true

if command -v colima > /dev/null; then
    echo ""
    echo "=========================================="
    echo "Colima"
    echo "=========================================="
    colima start > /dev/null 2>&1
    run_container_load_tests "Colima"
    colima stop > /dev/null 2>&1
fi

if [ -d "/Applications/OrbStack.app" ]; then
    echo ""
    echo "=========================================="
    echo "OrbStack"
    echo "=========================================="
    open -a OrbStack
    for i in $(seq 1 60); do orbctl status > /dev/null 2>&1 && break; sleep 1; done
    docker context use orbstack > /dev/null 2>&1 || true
    run_container_load_tests "OrbStack"
    osascript -e 'quit app "OrbStack"' > /dev/null 2>&1 || true
    sleep 3
    pgrep -f OrbStack > /dev/null 2>&1 && pkill -9 -f OrbStack 2>/dev/null || true
fi

docker context use "$ORIGINAL_CONTEXT" > /dev/null 2>&1 || true
rm -rf "$IMAGE_DIR"
