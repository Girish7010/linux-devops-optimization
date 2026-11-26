#!/usr/bin/env bash
# Threshold alerts for disk (all mounts), inodes, memory, CPU, load and failed systemd units.
# Sends to Slack and/or Telegram if configured, always logs to LOG_FILE.
# A cooldown stops the same alert from spamming you every 5 minutes.
#
# Config (optional): /etc/devops-optimization/alert.env  (see configs/alert.env.example)
# Usage: ./system_alert.sh            # normal run (cron every 5 min)
#        ./system_alert.sh --test     # send a test notification
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/devops-optimization/alert.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

DISK_THRESHOLD="${DISK_THRESHOLD:-80}"
INODE_THRESHOLD="${INODE_THRESHOLD:-80}"
MEM_THRESHOLD="${MEM_THRESHOLD:-85}"
CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
LOAD_PER_CORE_THRESHOLD="${LOAD_PER_CORE_THRESHOLD:-2}"
COOLDOWN_MIN="${COOLDOWN_MIN:-30}"
LOG_FILE="${LOG_FILE:-/var/log/system_alert.log}"
STATE_DIR="${STATE_DIR:-/var/tmp/system_alert}"

HOST="$(hostname)"
mkdir -p "$STATE_DIR"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/system_alert.log"

send() {
  local text="$1"
  if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    curl -fsS -m 10 -X POST -H 'Content-type: application/json' \
      --data "$(printf '{"text":"%s"}' "$text")" "$SLACK_WEBHOOK_URL" >/dev/null || true
  fi
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -m 10 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" --data-urlencode text="$text" >/dev/null || true
  fi
}

# alert KEY MESSAGE  -> logs + notifies, respecting cooldown per KEY
alert() {
  local key="$1" msg="$2" stamp
  stamp="$STATE_DIR/$(echo "$key" | tr '/ ' '__')"
  if [[ -f "$stamp" && -n "$(find "$stamp" -mmin -"$COOLDOWN_MIN" 2>/dev/null)" ]]; then
    return 0
  fi
  touch "$stamp"
  local line
  line="$(date '+%F %T') | $HOST | $msg"
  echo "$line" >> "$LOG_FILE"
  send "[ALERT] $line"
}

# resolve KEY -> clears cooldown and sends a recovery message if an alert was active
resolve() {
  local key="$1" msg="$2" stamp
  stamp="$STATE_DIR/$(echo "$key" | tr '/ ' '__')"
  if [[ -f "$stamp" ]]; then
    rm -f "$stamp"
    local line
    line="$(date '+%F %T') | $HOST | $msg"
    echo "$line" >> "$LOG_FILE"
    send "[RESOLVED] $line"
  fi
}

if [[ "${1:-}" == "--test" ]]; then
  send "[TEST] $(date '+%F %T') | $HOST | system_alert.sh notifications are working"
  echo "Test notification sent (check Slack/Telegram)."
  exit 0
fi

cpu_usage() {
  local a b idle1 idle2 tot1=0 tot2=0 i
  read -r -a a < <(grep '^cpu ' /proc/stat)
  sleep 1
  read -r -a b < <(grep '^cpu ' /proc/stat)
  idle1=$(( a[4] + a[5] ))
  idle2=$(( b[4] + b[5] ))
  for i in 1 2 3 4 5 6 7 8; do
    tot1=$(( tot1 + a[i] ))
    tot2=$(( tot2 + b[i] ))
  done
  (( tot2 - tot1 == 0 )) && { echo 0; return; }
  echo $(( 100 * ((tot2 - tot1) - (idle2 - idle1)) / (tot2 - tot1) ))
}

# --- Disk usage per real filesystem ---
while read -r pct mount; do
  if (( pct >= DISK_THRESHOLD )); then
    alert "disk$mount" "Disk usage on $mount is $pct% (threshold $DISK_THRESHOLD%)"
  else
    resolve "disk$mount" "Disk usage on $mount back to $pct%"
  fi
done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $5, $6}')

# --- Inode usage ---
while read -r pct mount; do
  [[ "$pct" =~ ^[0-9]+$ ]] || continue
  if (( pct >= INODE_THRESHOLD )); then
    alert "inode$mount" "Inode usage on $mount is $pct% (threshold $INODE_THRESHOLD%)"
  else
    resolve "inode$mount" "Inode usage on $mount back to $pct%"
  fi
done < <(df -P -i -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $5, $6}')

# --- Memory (uses MemAvailable, so page cache is not counted as "used") ---
MEM=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo)
if (( MEM >= MEM_THRESHOLD )); then
  TOP_MEM=$(ps -eo comm,%mem --sort=-%mem | awk 'NR>1 && NR<=4 {printf "%s(%s%%) ", $1, $2}')
  alert "mem" "Memory usage is $MEM% (threshold $MEM_THRESHOLD%). Top: $TOP_MEM"
else
  resolve "mem" "Memory usage back to $MEM%"
fi

# --- CPU ---
CPU=$(cpu_usage)
if (( CPU >= CPU_THRESHOLD )); then
  TOP_CPU=$(ps -eo comm,%cpu --sort=-%cpu | awk 'NR>1 && NR<=4 {printf "%s(%s%%) ", $1, $2}')
  alert "cpu" "CPU usage is $CPU% (threshold $CPU_THRESHOLD%). Top: $TOP_CPU"
else
  resolve "cpu" "CPU usage back to $CPU%"
fi

# --- Load average vs cores ---
CORES=$(nproc)
LOAD1=$(cut -d' ' -f1 /proc/loadavg)
if awk -v l="$LOAD1" -v c="$CORES" -v t="$LOAD_PER_CORE_THRESHOLD" 'BEGIN{exit !(l > c*t)}'; then
  alert "load" "Load average $LOAD1 on $CORES cores (threshold $LOAD_PER_CORE_THRESHOLD per core)"
else
  resolve "load" "Load average back to $LOAD1"
fi

# --- Failed systemd units ---
if command -v systemctl >/dev/null 2>&1; then
  FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd, -)
  if [[ -n "$FAILED" ]]; then
    alert "systemd" "Failed systemd units: $FAILED"
  else
    resolve "systemd" "No failed systemd units"
  fi
fi

exit 0
