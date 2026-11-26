#!/usr/bin/env bash
# Safe disk & log cleanup for Linux servers.
# - Only deletes OLD rotated logs and OLD temp files (never live files in use)
# - Never removes Docker volumes (no data loss)
# Usage: sudo ./cleanup.sh [--dry-run]
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
TMP_RETENTION_DAYS="${TMP_RETENTION_DAYS:-3}"
DOCKER_PRUNE_UNTIL="${DOCKER_PRUNE_UNTIL:-168h}"

run() {
  if (( DRY_RUN )); then
    echo "[dry-run] $*"
  else
    "$@" || echo "WARN: command failed: $*"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -ne 0 ]] && (( ! DRY_RUN )); then
  echo "Run as root (sudo) or use --dry-run" >&2
  exit 1
fi

echo "===== Cleanup started: $(date '+%F %T') ====="
echo "--- Disk before ---"
df -h / | tail -n 1

# 1. systemd journal: keep last N days
if have journalctl; then
  run journalctl --vacuum-time="${LOG_RETENTION_DAYS}d"
fi

# 2. Rotated / compressed logs older than N days (live *.log files are left to logrotate)
run find /var/log -xdev -type f '(' -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' -o -name '*.xz' ')' \
  -mtime +"$LOG_RETENTION_DAYS" -delete

# 3. Temp files not accessed for N days (safe: does not break running apps' sockets/locks)
run find /tmp /var/tmp -xdev -type f -atime +"$TMP_RETENTION_DAYS" -delete

# 4. Package manager cache
if have apt-get; then
  run apt-get -y autoremove --purge
  run apt-get -y clean
elif have dnf; then
  run dnf -y autoremove
  run dnf clean all
elif have yum; then
  run yum clean all
fi

# 5. Docker: unused images/containers/build cache older than DOCKER_PRUNE_UNTIL. Volumes are NOT touched.
if have docker && docker info >/dev/null 2>&1; then
  run docker system prune -af --filter "until=$DOCKER_PRUNE_UNTIL"
  run docker builder prune -af --filter "until=$DOCKER_PRUNE_UNTIL"
fi

# 6. Old snap revisions (Ubuntu)
if have snap; then
  snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r name rev; do
    run snap remove "$name" --revision="$rev"
  done
fi

echo "--- Disk after ---"
df -h / | tail -n 1
echo "===== Cleanup completed: $(date '+%F %T') ====="
