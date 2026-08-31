#!/bin/bash
# Measures darwin-runtimed's idle physical memory footprint using the
# same phys_footprint number MachMetricsSampler reports for jobs (see
# Sources/Telemetry/MachMetricsSampler.swift), read here via macOS's own
# `footprint` tool instead of RSS, since RSS is the same misleading
# number that turned out to be wrong for job metrics - see
# DEBUGGING_LOG.md #15.
#
# If Docker Desktop is running, also sums the footprint of every
# Docker-related process (the GUI app, its helpers, and the actual Linux
# VM host process), so the "no VM tax" claim has a real number behind
# it instead of just an assertion.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "building release binary (debug builds are not representative of real overhead)..."
swift build -c release --package-path "$REPO_ROOT" > /dev/null

DAEMON_PID=$(pgrep -f "release/darwin-runtimed" | head -1 || true)
if [ -z "$DAEMON_PID" ]; then
    echo "starting a release darwin-runtimed for measurement..."
    "$REPO_ROOT/.build/release/darwin-runtimed" > /dev/null 2>&1 &
    DAEMON_PID=$!
    sleep 1
    STARTED_IT=1
else
    STARTED_IT=0
fi

echo ""
echo "=== darwin-runtimed: idle physical footprint ==="
footprint "$DAEMON_PID" | grep "Footprint:"

if [ "$STARTED_IT" = "1" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
fi

if pgrep -f "Docker Desktop" > /dev/null 2>&1 || pgrep -f "com.docker" > /dev/null 2>&1; then
    echo ""
    echo "=== Docker Desktop: idle physical footprint (sum of all its processes) ==="
    TOTAL_KB=0
    for pid in $(pgrep -f "Docker Desktop|com\.docker"); do
        LINE=$(footprint "$pid" 2>/dev/null | grep "Footprint:" || true)
        [ -z "$LINE" ] && continue
        echo "$LINE"
        VALUE=$(echo "$LINE" | grep -oE "Footprint: [0-9]+ (MB|KB)" | grep -oE "[0-9]+")
        UNIT=$(echo "$LINE" | grep -oE "Footprint: [0-9]+ (MB|KB)" | grep -oE "MB|KB")
        if [ "$UNIT" = "MB" ]; then
            TOTAL_KB=$((TOTAL_KB + VALUE * 1024))
        else
            TOTAL_KB=$((TOTAL_KB + VALUE))
        fi
    done
    echo "---"
    echo "total: $((TOTAL_KB / 1024)) MB across all Docker Desktop processes"
else
    echo ""
    echo "Docker Desktop is not running - skipping comparison."
    echo "(To compare, run: open -a Docker, wait for it to be ready, then re-run this script.)"
fi
