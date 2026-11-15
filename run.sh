#!/usr/bin/env bash
# Inference session: free VRAM, tune the kernel, run llama-server, stream logs.
#
# Ctrl+C (or a container failure) stops the model, archives forensics to
# logs/, restores the CPU governor and the desktop, and exits with the
# real status code.
#
# Environment:
#   ISOLATE_DESKTOP=0   keep the desktop running (refused in a GUI session
#                       unless set) - for testing without tearing down X
#   DROP_CACHES=1       drop page cache before start (off by default: with
#                       mmap'd models it only slows the next load)
set -euo pipefail

COMPOSE="docker compose --profile llama"
SERVICE="llama-server"
LOG_DIR="$PWD/logs"

ISOLATE_DESKTOP="${ISOLATE_DESKTOP:-1}"
DROP_CACHES="${DROP_CACHES:-0}"

# --- Guard: isolate multi-user.target kills a graphical terminal ------------
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    echo "error: running in a graphical session (DISPLAY=${DISPLAY:-}, WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-})." >&2
    echo "       'systemctl isolate multi-user.target' would kill this terminal mid-script." >&2
    echo "       Run from a TTY (Ctrl+Alt+F3) or set ISOLATE_DESKTOP=0 to keep the desktop." >&2
    exit 1
fi

# --- Acquire sudo BEFORE the desktop is gone (no password prompt later) -----
sudo -v
( while sleep 60; do sudo -n true 2>/dev/null || true; done ) &
SUDO_KEEPALIVE=$!

# Remember the governor to restore it on exit (it was never restored before).
GOV_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
prev_governor="$(cat "$GOV_PATH" 2>/dev/null || true)"

started=0

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    kill "$SUDO_KEEPALIVE" 2>/dev/null || true

    if [[ $started -eq 1 ]]; then
        echo -e "\n[*] Stopping $SERVICE ..."
        $COMPOSE stop "$SERVICE" >/dev/null 2>&1 || true

        # --- Forensics for post-mortem: logs + exit state + kernel messages ---
        local ts cid
        ts="$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$LOG_DIR"
        $COMPOSE logs --no-color "$SERVICE" > "$LOG_DIR/llama-$ts.log" 2>&1 || true
        cid="$($COMPOSE ps -aq "$SERVICE" 2>/dev/null || true)"
        if [[ -n "$cid" ]]; then
            docker inspect "$cid" --format \
                "container=${cid:0:12} status={{.State.Status}} exit_code={{.State.ExitCode}} oom_killed={{.State.OOMKilled}}" \
                > "$LOG_DIR/llama-$ts.inspect" 2>/dev/null || true
        fi
        sudo journalctl -k -b --no-pager 2>/dev/null \
            | grep -iE "amdgpu|kfd|gpu|out of memory|oom-kill" > "$LOG_DIR/llama-$ts.kernel.log" || true
        echo "[*] Session forensics: $LOG_DIR/llama-$ts.*"
    fi

    if [[ -n "$prev_governor" && "$prev_governor" != "performance" ]]; then
        echo "[*] Restoring CPU governor: $prev_governor"
        sudo cpupower frequency-set -g "$prev_governor" >/dev/null 2>&1 || true
    fi

    if [[ "$ISOLATE_DESKTOP" == "1" ]]; then
        echo "[*] Restoring desktop ..."
        sudo systemctl isolate graphical.target
    fi
    exit "$rc"
}
# Single EXIT trap: INT/TERM only translate to an exit code, so cleanup
# runs exactly once (the old INT TERM EXIT trap double-isolated the desktop).
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

echo "[1/4] Freeing VRAM: isolating multi-user.target (stopping desktop)..."
if [[ "$ISOLATE_DESKTOP" == "1" ]]; then
    sudo systemctl isolate multi-user.target
    sleep 1
fi

echo "[2/4] Kernel tuning: governor=performance (drop_caches: $DROP_CACHES)..."
if [[ "$DROP_CACHES" == "1" ]]; then
    sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
fi
sudo cpupower frequency-set -g performance >/dev/null 2>&1 || true

echo "[3/4] Launching $SERVICE (blocks until the model is loaded)..."
$COMPOSE up -d --wait "$SERVICE"
started=1

echo "[4/4] Attaching to live logs. Ctrl+C: stop model, archive logs, restore desktop."
$COMPOSE logs -f "$SERVICE"
