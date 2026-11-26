#!/usr/bin/env bash
# Compressed backup of important directories with retention and optional upload to S3.
#
# Config via env or /etc/devops-optimization/backup.env:
#   BACKUP_PATHS="/etc /opt/app /home/ubuntu"   # what to back up (default: /etc)
#   BACKUP_DIR=/var/backups/devops-optimization  # where archives are stored
#   RETENTION_DAYS=7                             # local retention
#   S3_BUCKET=s3://my-bucket/backups             # optional, needs aws cli + IAM role
# Usage: sudo ./backup.sh
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/devops-optimization/backup.env}"
# shellcheck disable=SC1090
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

BACKUP_PATHS="${BACKUP_PATHS:-/etc}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/devops-optimization}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
S3_BUCKET="${S3_BUCKET:-}"

HOST="$(hostname -s)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/$HOST-$STAMP.tar.gz"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

echo "===== Backup started: $(date '+%F %T') ====="
read -r -a PATHS <<< "$BACKUP_PATHS"
EXISTING=()
for p in "${PATHS[@]}"; do
  if [[ -e "$p" ]]; then EXISTING+=("$p"); else echo "WARN: $p does not exist, skipping"; fi
done
if (( ${#EXISTING[@]} == 0 )); then
  echo "Nothing to back up" >&2
  exit 1
fi

tar --warning=no-file-changed -czpf "$ARCHIVE" \
  --exclude='*.sock' --exclude='node_modules' --exclude='.cache' \
  "${EXISTING[@]}" || [[ $? -eq 1 ]]   # exit 1 = files changed while reading; archive is still usable
chmod 600 "$ARCHIVE"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "Created $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# Verify archive is readable
tar -tzf "$ARCHIVE" >/dev/null && echo "Archive verified OK"

if [[ -n "$S3_BUCKET" ]]; then
  if command -v aws >/dev/null 2>&1; then
    aws s3 cp "$ARCHIVE" "$S3_BUCKET/$HOST/" --only-show-errors
    aws s3 cp "$ARCHIVE.sha256" "$S3_BUCKET/$HOST/" --only-show-errors
    echo "Uploaded to $S3_BUCKET/$HOST/"
  else
    echo "WARN: S3_BUCKET set but aws cli not installed" >&2
  fi
fi

# Local retention
find "$BACKUP_DIR" -maxdepth 1 -type f -name "$HOST-*.tar.gz*" -mtime +"$RETENTION_DAYS" -print -delete

echo "===== Backup completed: $(date '+%F %T') ====="
