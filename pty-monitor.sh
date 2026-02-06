#!/bin/bash
# pty-monitor — Monitor and clean up leaked PTY devices from Copilot CLI
#
# Level 1 (auto-kill): orphaned copilot processes (PPID=1, no TTY)
# Level 2 (alert): copilot processes with >150 leaked ptmx FDs
# Level 3 (alert): total PTY usage >80% of kern.tty.ptmx_max
#
# Deduplication: alerts are suppressed for 30 minutes after last alert
# to avoid notification spam when running on schedule.
#
# Usage:
#   pty-monitor              # run once (kill zombies + alert if needed)
#   pty-monitor --status     # show current PTY status table
#   pty-monitor --dry-run    # show what would happen, don't kill/notify
#   pty-monitor --force      # ignore dedup, always notify

set -euo pipefail

DRY_RUN=false
STATUS_ONLY=false
FORCE=false
PTMX_WARN_THRESHOLD=150
USAGE_WARN_PERCENT=80
LOG_FILE="/tmp/pty-monitor.log"
LAST_ALERT_FILE="/tmp/pty-monitor-last-alert"
ALERT_COOLDOWN=1800  # 30 minutes

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --status) STATUS_ONLY=true ;;
    --force) FORCE=true ;;
  esac
done

# --- helpers ---

should_alert() {
  $FORCE && return 0
  if [[ -f "$LAST_ALERT_FILE" ]]; then
    local last now diff
    last=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    diff=$((now - last))
    [[ $diff -lt $ALERT_COOLDOWN ]] && return 1
  fi
  return 0
}

mark_alerted() {
  date +%s > "$LAST_ALERT_FILE"
}

notify() {
  local title="$1" message="$2"
  if $DRY_RUN; then
    log "[DRY-RUN] Would notify: $title — $message"
    return
  fi
  osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
  if command -v notify-telegram &>/dev/null; then
    notify-telegram "$title: $message" 2>/dev/null || true
  fi
  log "$title: $message"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

get_copilot_pids() {
  local pids=""
  for pid in $(pgrep -f 'copilot.*--resume' 2>/dev/null || true); do
    local comm
    comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    [[ "$comm" == "node" ]] && continue
    pids="$pids $pid"
  done
  echo "$pids"
}

get_process_info() {
  local pid="$1"
  local tty cpu ppid ptmx cwd project
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')
  ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  ptmx=$(lsof -p "$pid" 2>/dev/null | grep -c ptmx || echo 0)
  cwd=$(lsof -p "$pid" 2>/dev/null | awk '/cwd/{print $NF}')
  project=$(basename "$cwd" 2>/dev/null || echo "?")
  echo "$tty|$cpu|$ppid|$ptmx|$project"
}

# --- gather data ---

PTY_MAX=$(sysctl -n kern.tty.ptmx_max 2>/dev/null || echo 999)
PTY_USED=$(ls /dev/ttys[0-9][0-9][0-9] 2>/dev/null | wc -l | tr -d ' ')
PTY_FREE=$((PTY_MAX - PTY_USED))
PTY_USAGE_PERCENT=$((PTY_USED * 100 / PTY_MAX))

# --- status mode ---

if $STATUS_ONLY; then
  echo "PTY: ${PTY_USED}/${PTY_MAX} used (${PTY_USAGE_PERCENT}%), ${PTY_FREE} free"
  echo ""

  pids=$(get_copilot_pids)
  if [ -z "$pids" ]; then
    echo "No Copilot CLI processes."
    exit 0
  fi

  printf "%-8s %-10s %-6s %-8s %s\n" "PID" "TTY" "CPU%" "ptmx" "Project"
  printf "%-8s %-10s %-6s %-8s %s\n" "---" "---" "---" "---" "---"

  worst_pid="" worst_ptmx=0
  for pid in $pids; do
    IFS='|' read -r tty cpu ppid ptmx project <<< "$(get_process_info "$pid")"
    flag=""
    [[ "$ppid" == "1" && "$tty" == "??" ]] && flag=" ZOMBIE"
    [[ "$ptmx" -gt "$PTMX_WARN_THRESHOLD" ]] && flag="${flag} LEAK!"
    printf "%-8s %-10s %-6s %-8s %s%s\n" "$pid" "$tty" "$cpu" "$ptmx" "$project" "$flag"
    if [[ "$ptmx" -gt "$worst_ptmx" ]]; then
      worst_ptmx=$ptmx
      worst_pid=$pid
    fi
  done

  if [[ "$PTY_USAGE_PERCENT" -ge "$USAGE_WARN_PERCENT" && -n "$worst_pid" ]]; then
    IFS='|' read -r tty _ _ _ project <<< "$(get_process_info "$worst_pid")"
    echo ""
    echo "Restart recommendation: kill PID $worst_pid ($project in $tty)"
    echo "  -> frees ~${worst_ptmx} PTYs, then 'copilot --resume' in that terminal"
  fi
  exit 0
fi

# --- Level 1: kill orphaned copilot processes ---

KILLED=0
KILLED_DETAILS=""
pids=$(get_copilot_pids)

for pid in $pids; do
  IFS='|' read -r tty cpu ppid ptmx project <<< "$(get_process_info "$pid")"

  if [[ "$ppid" == "1" && "$tty" == "??" ]]; then
    if $DRY_RUN; then
      log "[DRY-RUN] Would kill zombie PID=$pid $project CPU=${cpu}%"
    else
      kill "$pid" 2>/dev/null && {
        KILLED=$((KILLED + 1))
        KILLED_DETAILS="${KILLED_DETAILS}${project} (PID $pid), "
        log "Killed zombie PID=$pid $project CPU=${cpu}%"
      } || log "Failed to kill PID=$pid"
    fi
  fi
done

if [[ $KILLED -gt 0 ]]; then
  notify "PTY Cleanup" "Killed $KILLED zombie: ${KILLED_DETAILS%, }"
fi

# --- Levels 2+3: alert about leaks and usage (with dedup) ---

# Re-read after cleanup
PTY_USED=$(ls /dev/ttys[0-9][0-9][0-9] 2>/dev/null | wc -l | tr -d ' ')
PTY_FREE=$((PTY_MAX - PTY_USED))
PTY_USAGE_PERCENT=$((PTY_USED * 100 / PTY_MAX))

if [[ "$PTY_USAGE_PERCENT" -ge "$USAGE_WARN_PERCENT" ]] && should_alert; then
  # Collect all processes sorted by ptmx count for actionable report
  details=""
  for pid in $pids; do
    ps -p "$pid" &>/dev/null || continue
    IFS='|' read -r tty cpu ppid ptmx project <<< "$(get_process_info "$pid")"
    [[ "$ptmx" -gt 0 ]] && details="${details}${ptmx}|${project}|${tty}|${pid}\n"
  done

  # Sort by ptmx descending, format as readable list
  process_list=$(echo -e "$details" | sort -t'|' -k1 -rn | while IFS='|' read -r ptmx project tty pid; do
    [[ -z "$pid" ]] && continue
    echo "${project} (${tty}): ${ptmx} ptmx"
  done)

  msg="PTY ${PTY_USED}/${PTY_MAX} (${PTY_FREE} free)"
  notify "PTY Warning" "${msg}
${process_list}"
  mark_alerted
fi

# --- quiet log ---
log "Check: PTY ${PTY_USED}/${PTY_MAX} (${PTY_USAGE_PERCENT}%), killed: ${KILLED}"
