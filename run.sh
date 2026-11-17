#!/usr/bin/env bash
# Inference session: free VRAM, tune the kernel, run llama-server, stream logs.
#
# Ctrl+C (or a container failure) stops the model, archives forensics to
# logs/, restores the CPU governor and the desktop, and exits with the
# real status code.
#
# Environment (exported variables win; otherwise .env is sourced - the same
# file compose reads, so the KV mount and the snapshot agents can't drift):
#   ISOLATE_DESKTOP=0   keep the desktop running (refused in a GUI session
#                       unless set) - for testing without tearing down X
#   DROP_CACHES=1       drop page cache before start (off by default: with
#                       mmap'd models it only slows the next load)
#   LLAMA_URL, LLAMA_CACHE_DIR, LLAMA_CACHE_FILE, SAVE_MIN_TOKENS,
#   SAVE_INTERVAL       KV snapshot behaviour (defaults below)
set -euo pipefail

COMPOSE="docker compose --profile llama"
SERVICE="llama-server"
LOG_DIR="$PWD/logs"

# Single source of truth: honor the same .env that compose reads, so
# LLAMA_CACHE_DIR (and friends) cannot drift between the mount and the agents.
# Real environment variables win (exported before the source).
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source ./.env
    set +a
fi

ISOLATE_DESKTOP="${ISOLATE_DESKTOP:-1}"
DROP_CACHES="${DROP_CACHES:-0}"

# --- KV snapshot (auto save/restore of the conversation cache) ---------------
# llama.cpp --slot-save-path enables POST /slots/0?action=save|restore.
# We restore the snapshot right after start and keep re-saving it while the
# slot is idle, so restarting the model does not re-prefill the 50-80k lore.
LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8080}"
CACHE_DIR="${LLAMA_CACHE_DIR:-/mnt/AI/cache}"
CACHE_FILE="${LLAMA_CACHE_FILE:-qwen27b-context.bin}"
SAVE_MIN_TOKENS="${SAVE_MIN_TOKENS:-2048}"
SAVE_INTERVAL="${SAVE_INTERVAL:-60}"
API_KEY="$(cat "$PWD/secrets/llama_api_key" 2>/dev/null || true)"

TTY_DEVICE="$(tty 2>/dev/null || true)"

if [[ -z "$TTY_DEVICE" || "$TTY_DEVICE" == "not a tty" ]]; then
    echo "error: script must be launched from a TTY." >&2
    exit 1
fi

# api METHOD PATH [JSON-BODY] [MAX-TIME]
api() {
    local method="$1" path="$2" body="${3:-}" t="${4:-30}"
    if [[ -n "$body" ]]; then
        curl -s --max-time "$t" -X "$method" \
            -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
            -d "$body" "$LLAMA_URL$path"
    else
        curl -s --max-time "$t" -X "$method" \
            -H "Authorization: Bearer $API_KEY" "$LLAMA_URL$path"
    fi
}

wait_server_ready() {
    until curl -s -f "$LLAMA_URL/health" >/dev/null 2>&1; do sleep 1; done
}

# Restore the KV snapshot once. Started BEFORE `up -d --wait`: that waits for
# the 15s-interval healthcheck, so waiting for it would leave up to ~15 s where
# a client (phone) can prefill the full history first. Polling /health directly
# closes that window.
restore_agent() {
    wait_server_ready
    if [[ ! -f "$CACHE_DIR/$CACHE_FILE" ]]; then
        echo "[*] No snapshot $CACHE_DIR/$CACHE_FILE - starting with a clean slot."
        return 0
    fi
    # Never restore over a slot a client already filled: that state is newer
    # than the snapshot and restoring would roll the conversation back.
    local state toks
    state="$(api GET /slots '' 10)" || state="[]"
    toks="$(jq -r '.[0].n_prompt_tokens // 0' <<<"$state" 2>/dev/null || echo 0)"
    if [[ "$toks" =~ ^[0-9]+$ && "$toks" -gt 0 ]]; then
        echo "[!] A client already sent a $toks-token prompt before the restore."
        echo "    Skipping restore (the live slot state is newer than the snapshot)."
        return 0
    fi
    echo "[*] Restoring KV snapshot $CACHE_FILE (next response re-prefills"
    echo "    only the new tokens, not the whole history) ..."
    local out
    out="$(api POST "/slots/0?action=restore" "{\"filename\": \"$CACHE_FILE\"}" 300)" || true
    echo "[+] $out"
}

# Keep the snapshot fresh: save whenever the slot is idle with a real prompt.
save_loop() {
    wait_server_ready
    sleep 5
    while :; do
        sleep "$SAVE_INTERVAL"
        local state toks busy
        state="$(api GET /slots '' 10)" || continue
        toks="$(jq -r '.[0].n_prompt_tokens // 0' <<<"$state" 2>/dev/null || echo 0)"
        busy="$(jq -r '.[0].is_processing // false' <<<"$state" 2>/dev/null || echo true)"
        [[ "$busy" == "false" && "$toks" =~ ^[0-9]+$ && "$toks" -ge "$SAVE_MIN_TOKENS" ]] || continue
        echo "[*] Saving KV snapshot ($toks tokens) -> $CACHE_DIR/$CACHE_FILE"
        local out
        out="$(api POST "/slots/0?action=save" "{\"filename\": \"$CACHE_FILE\"}" 300)" || continue
        echo "$out" | grep -q '"error"' || echo "[+] Snapshot saved: $out"
    done
}

# Terminal watchdog: whatever runs on this tty (a TUI killed mid-run, a
# crashed pager) can leave it raw - no echo, and Ctrl+C dead for the whole
# session. Re-heal it every 5 s while the session is active, so Ctrl+C
# always works no matter what. Fires only when the tty is actually broken,
# and dumps forensics (processes on the tty at the moment of healing) so a
# repeat can be attributed.
tty_watchdog() {
    local lost ts

    while :; do
        sleep 2

        lost="$(
            stty -F "$TTY_DEVICE" -a 2>/dev/null |
            grep -oE -- '-(isig|icanon|echo|opost|onlcr)\b' |
            sort -u |
            tr -cd 'a-z ' |
            tr -s ' '
        )"

        [[ -n "${lost//[[:space:]]/}" ]] || continue

        stty -F "$TTY_DEVICE" sane 2>/dev/null || true

        ts="$(date +%H%M%S)"
        mkdir -p "$LOG_DIR"

        {
            echo "healed $(date '+%F %T') lost-flags: $lost"
            echo "--- processes with a tty at healing time:"
            ps -eo pid,ppid,tty,stat,etime,cmd |
                awk 'NR==1 || $3 ~ /^(tty|pts)/'
        } > "$LOG_DIR/tty-heal-$ts.txt" 2>&1 || true

        echo "[!] Terminal was left in broken mode (lost: $lost)."
        echo "    Restored with stty sane."
        echo "    Forensics: $LOG_DIR/tty-heal-$ts.txt"
    done
}

# Final snapshot before the container stops. The slot must be idle: if the
# model is still generating, stop the generation in the client to speed this up.
save_final() {
    local out
    echo -e "\n[*] Saving final KV snapshot -> $CACHE_DIR/$CACHE_FILE (up to 120 s)"
    out="$(api POST "/slots/0?action=save" "{\"filename\": \"$CACHE_FILE\"}" 120)" || true
    echo "$out" | grep -q '"error"' && echo "[!] Final snapshot failed (slot busy?)" || echo "[+] $out"
}

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
RESTORE_PID=""
SAVE_PID=""
TTY_PID=""

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    kill "$SUDO_KEEPALIVE" 2>/dev/null || true
    [[ -n "$RESTORE_PID" ]] && kill "$RESTORE_PID" 2>/dev/null || true
    [[ -n "$SAVE_PID" ]] && kill "$SAVE_PID" 2>/dev/null || true
    [[ -n "$TTY_PID" ]] && kill "$TTY_PID" 2>/dev/null || true

    if [[ $started -eq 1 ]]; then
        save_final
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

    # Leave the terminal in a usable state no matter how the session ended.
    stty -F "$TTY_DEVICE" sane 2>/dev/null || true
    exit "$rc"
}
# Single EXIT trap: INT/TERM only translate to an exit code, so cleanup
# runs exactly once (the old INT TERM EXIT trap double-isolated the desktop).
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

# Self-heal the terminal: a TUI killed on this tty (nvtop, qwen, opencode,
# ...) leaves it in raw mode - no echo, and Ctrl+C dead for the whole session.
stty sane 2>/dev/null || true

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

# KV-snapshot agents start NOW (not after --wait): they poll /health
# themselves, and the restore must land before the first client request can.
restore_agent & RESTORE_PID=$!
save_loop & SAVE_PID=$!
tty_watchdog & TTY_PID=$!

echo "[3/4] Launching $SERVICE (blocks until the model is loaded)..."
$COMPOSE up -d --wait "$SERVICE"
started=1

echo "[4/4] Attaching to live logs. Ctrl+C: stop model, archive logs, restore desktop."
$COMPOSE logs -f "$SERVICE"
