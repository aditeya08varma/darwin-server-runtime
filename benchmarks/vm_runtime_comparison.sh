#!/bin/bash
# Compares darwin-runtimed against three other ways to get containers on
# macOS: Docker Desktop, Lima (a bare VM launcher, no container runtime
# of its own), Colima (Docker via Lima, no GUI), and OrbStack (a
# from-scratch lightweight VM + container runtime marketed specifically
# as a lean Docker Desktop alternative).
#
# This exists because comparing only against Docker Desktop invites a
# fair objection: its ~464MB idle footprint is mostly its Electron GUI,
# not the VM mechanism itself. Lima/Colima/OrbStack have no mandatory
# GUI, so they isolate the actual "run a Linux VM to get containers on
# macOS" cost from the "also ship a dashboard app" cost.
#
# Requires: brew install lima colima && brew install --cask orbstack
#
# Each tool is started, measured, and fully stopped before the next one
# starts, so measurements don't contaminate each other by running
# multiple VMs at once.
set -euo pipefail

if ! command -v hyperfine > /dev/null; then
    echo "hyperfine is required: brew install hyperfine"
    exit 1
fi
if ! command -v limactl > /dev/null || ! command -v colima > /dev/null; then
    echo "lima and colima are required: brew install lima colima"
    exit 1
fi
if [ ! -d "/Applications/OrbStack.app" ]; then
    echo "OrbStack is required: brew install --cask orbstack"
    exit 1
fi

ORIGINAL_CONTEXT=$(docker context show 2>/dev/null || echo "default")

sum_footprint() {
    local total_kb=0
    for pid in "$@"; do
        local line
        line=$(footprint "$pid" 2>/dev/null | grep "Footprint:" || true)
        [ -z "$line" ] && continue
        local value unit
        value=$(echo "$line" | grep -oE "Footprint: [0-9]+ (MB|KB)" | grep -oE "[0-9]+")
        unit=$(echo "$line" | grep -oE "Footprint: [0-9]+ (MB|KB)" | grep -oE "MB|KB")
        if [ "$unit" = "MB" ]; then
            total_kb=$((total_kb + value * 1024))
        else
            total_kb=$((total_kb + value))
        fi
    done
    echo "$((total_kb / 1024)) MB"
}

echo "=== Lima (bare VM, no container runtime - isolates raw VM cost) ==="
limactl start --name=bench --tty=false > /dev/null 2>&1
LIMA_PIDS=$(pgrep -f "com.apple.Virtualization.VirtualMachine|limactl hostagent.*bench|ssh.*bench" || true)
echo "idle footprint: $(sum_footprint $LIMA_PIDS)"
limactl stop bench > /dev/null 2>&1
limactl delete bench > /dev/null 2>&1

echo ""
echo "=== Colima (Docker via Lima, no GUI) ==="
colima start > /dev/null 2>&1
docker pull alpine:latest > /dev/null 2>&1
COLIMA_PIDS=$(pgrep -f "com.apple.Virtualization.VirtualMachine|limactl hostagent.*colima|limactl usernet" || true)
echo "idle footprint: $(sum_footprint $COLIMA_PIDS)"
hyperfine --warmup 3 --min-runs 30 -n "docker run (Colima)" "docker run -d --rm alpine:latest true"
colima stop > /dev/null 2>&1

echo ""
echo "=== OrbStack ==="
open -a OrbStack
for i in $(seq 1 60); do
    orbctl status > /dev/null 2>&1 && break
    sleep 1
done
docker pull alpine:latest > /dev/null 2>&1
ORB_PIDS=$(pgrep -f "OrbStack" || true)
echo "idle footprint: $(sum_footprint $ORB_PIDS) (excludes the small root-owned privhelper - footprint needs root to read it)"
hyperfine --warmup 3 --min-runs 30 -n "docker run (OrbStack)" "docker run -d --rm alpine:latest true"
osascript -e 'quit app "OrbStack"' 2>&1 > /dev/null

docker context use "$ORIGINAL_CONTEXT" > /dev/null 2>&1 || true

echo ""
echo "For Docker Desktop and darwin-runtimed numbers, see memory_footprint.sh and cold_start.sh."
