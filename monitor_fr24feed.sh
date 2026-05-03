#!/bin/bash
# FR24Feed monitor with graduated recovery.
#
# Escalation ladder (one cron tick, ~5 min, between steps):
#   level 0: healthy, no action
#   level 1: restart fr24feed.service        (most failures recover here)
#   level 2: USB reauth on the RTL-SDR       (no-op if dongle not on bus)
#   level 3: reboot the Pi                   (last resort)
#
# Debounce: require CONSECUTIVE_FAILS_THRESHOLD ticks of "unhealthy" before
# any action. Prevents false alarms during quiet-traffic windows where
# fr24feed-status briefly reports zero messages simply because no aircraft are
# in range. A real failure stays unhealthy for many ticks, so it still escalates.
#
# State persists across cron invocations in STATE_FILE; resets on recovery.
# Run as the pi user from cron — relies on passwordless sudo (default on Pi OS).

set -u

LOG_FILE="/home/pi/logs/fr24feed_monitor.log"     # on SD card — survives reboots, unlike /var/log on tmpfs
LOG_DIR="/home/pi/logs"
STATE_FILE="/var/lib/fr24-monitor/state"
MIN_UPTIME_MIN=15
ESCALATE_AFTER_SEC=240        # wait at least this long between escalation steps
RTL_VENDOR_ID="0bda"          # Realtek — covers nearly all RTL-SDR dongles
MAX_LOG_BYTES=10485760        # 10 MB
CONSECUTIVE_FAILS_THRESHOLD=2 # need this many ticks of "unhealthy" in a row before acting

# is_healthy() exit codes:
#   0 = healthy        (receiver connected, messages flowing)
#   1 = unhealthy      (receiver down, or explicit "0 MSGS" steady-state)
#   2 = indeterminate  (post-restart warmup — empty MSGS field, don't touch state)

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }

uptime_min() { awk '{print int($1/60)}' /proc/uptime; }

ensure_log_dir() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
}

rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    [ "$size" -gt "$MAX_LOG_BYTES" ] && mv "$LOG_FILE" "$LOG_FILE.old"
}

ensure_state_dir() {
    local d
    d=$(dirname "$STATE_FILE")
    [ -d "$d" ] || sudo mkdir -p "$d"
}

read_state() {
    LEVEL=0
    LAST_ACTION_TS=0
    FIRST_FAIL_TS=0
    CONSECUTIVE_FAILS=0
    if sudo test -f "$STATE_FILE"; then
        # shellcheck disable=SC1090
        eval "$(sudo cat "$STATE_FILE")"
    fi
}

write_state() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
LEVEL=$LEVEL
LAST_ACTION_TS=$LAST_ACTION_TS
FIRST_FAIL_TS=$FIRST_FAIL_TS
CONSECUTIVE_FAILS=$CONSECUTIVE_FAILS
EOF
    sudo mv "$tmp" "$STATE_FILE"
}

is_healthy() {
    local out
    out=$(/usr/bin/fr24feed-status 2>&1)
    log "status: $(echo "$out" | tr '\n' '|' | sed 's/|$//')"
    echo "$out" | grep -q "Receiver: down"             && return 1
    echo "$out" | grep -q "Receiver: connected ( MSGS" && return 2  # empty field — warming up after restart
    echo "$out" | grep -q "Receiver: connected (0 MSGS" && return 1
    return 0
}

action_restart_service() {
    log "level 1: restarting fr24feed.service"
    sudo systemctl restart fr24feed
}

action_reset_dongle() {
    log "level 2: USB reauth on RTL-SDR (vendor $RTL_VENDOR_ID)"
    local found=0
    for v in /sys/bus/usb/devices/*/idVendor; do
        [ -r "$v" ] || continue
        if [ "$(cat "$v" 2>/dev/null)" = "$RTL_VENDOR_ID" ]; then
            local path
            path=$(dirname "$v")
            log "  toggling authorized on $path"
            echo 0 | sudo tee "$path/authorized" >/dev/null || true
            sleep 2
            echo 1 | sudo tee "$path/authorized" >/dev/null || true
            found=1
        fi
    done
    [ "$found" -eq 0 ] && log "  no RTL-SDR on bus — nothing to reauth (will escalate next tick)"
    sudo systemctl restart fr24feed
}

action_reboot() {
    log "level 3: rebooting Pi (receiver still down after service restart + USB reauth)"
    wall "FR24 monitor: rebooting Pi (receiver down)" 2>/dev/null || true
    sleep 5
    sudo /sbin/shutdown -r now
}

main() {
    ensure_log_dir
    rotate_log
    ensure_state_dir
    read_state

    local up
    up=$(uptime_min)
    if [ "$up" -lt "$MIN_UPTIME_MIN" ]; then
        log "uptime ${up}m < ${MIN_UPTIME_MIN}m — skipping"
        exit 0
    fi

    local now
    now=$(date +%s)

    is_healthy
    local health=$?

    if [ "$health" -eq 2 ]; then
        # Empty MSGS field — fr24feed restarted recently and the stats counter
        # has not refreshed yet. Don't claim recovery, don't claim failure;
        # just wait for the next tick to get a real reading.
        log "status indeterminate (post-restart warmup) — leaving state at level $LEVEL"
        exit 0
    fi

    if [ "$health" -eq 0 ]; then
        if [ "$LEVEL" -ne 0 ]; then
            local dur=$(( now - FIRST_FAIL_TS ))
            log "RECOVERED at level $LEVEL after ${dur}s — resetting state"
            LEVEL=0; LAST_ACTION_TS=0; FIRST_FAIL_TS=0; CONSECUTIVE_FAILS=0
            write_state
        elif [ "$CONSECUTIVE_FAILS" -gt 0 ]; then
            log "transient unhealthy resolved (had ${CONSECUTIVE_FAILS} consecutive fail(s), no action taken)"
            CONSECUTIVE_FAILS=0
            write_state
        fi
        exit 0
    fi

    # health == 1 (unhealthy)
    [ "$FIRST_FAIL_TS" -eq 0 ] && FIRST_FAIL_TS=$now
    CONSECUTIVE_FAILS=$(( CONSECUTIVE_FAILS + 1 ))

    if [ "$LEVEL" -eq 0 ] && [ "$CONSECUTIVE_FAILS" -lt "$CONSECUTIVE_FAILS_THRESHOLD" ]; then
        log "unhealthy ${CONSECUTIVE_FAILS}/${CONSECUTIVE_FAILS_THRESHOLD} consecutive — waiting for confirmation before acting"
        write_state
        exit 0
    fi

    local since_last=$(( now - LAST_ACTION_TS ))
    if [ "$LEVEL" -ge 1 ] && [ "$since_last" -lt "$ESCALATE_AFTER_SEC" ]; then
        log "unhealthy at level $LEVEL, last action ${since_last}s ago (<${ESCALATE_AFTER_SEC}s) — waiting"
        write_state
        exit 0
    fi

    case "$LEVEL" in
        0) LEVEL=1; LAST_ACTION_TS=$now; write_state; action_restart_service ;;
        1) LEVEL=2; LAST_ACTION_TS=$now; write_state; action_reset_dongle ;;
        2) LEVEL=3; LAST_ACTION_TS=$now; write_state; action_reboot ;;
        3) log "already at level 3 — waiting for reboot to take effect" ;;
    esac
}

main "$@"
