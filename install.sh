#!/usr/bin/env bash
# One-command installer for linux-devops-optimization.
# Idempotent: safe to re-run. Backs up any file it replaces (*.bak-<timestamp>).
#
# Usage:
#   sudo ./install.sh --dry-run              # show what would change
#   sudo ./install.sh                        # install scripts, configs, cron
#   sudo ./install.sh --install-packages     # also install fail2ban, unattended-upgrades, zram, lsof...
#   sudo ./install.sh --with-ssh-hardening   # also apply SSH hardening (key login required!)
#   sudo ./install.sh --skip-docker          # do not touch /etc/docker/daemon.json
#   sudo ./install.sh --uninstall            # remove everything this script installed
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="/opt/devops-optimization"
ETC_DIR="/etc/devops-optimization"
LOG_DIR="/var/log/devops-optimization"
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY_RUN=0; INSTALL_PKGS=0; SSH_HARDEN=0; SKIP_DOCKER=0; UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --install-packages) INSTALL_PKGS=1 ;;
    --with-ssh-hardening) SSH_HARDEN=1 ;;
    --skip-docker) SKIP_DOCKER=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mWARN:\033[0m %s\n' "$*"; }
run()  { if (( DRY_RUN )); then echo "    [dry-run] $*"; else "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }

# install_file SRC DEST MODE -> copies, backing up DEST if it differs
install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    echo "    unchanged: $dest"
    return 0
  fi
  if [[ -f "$dest" ]]; then
    run cp -a "$dest" "$dest.bak-$STAMP"
    echo "    backup:    $dest.bak-$STAMP"
  fi
  run install -D -m "$mode" "$src" "$dest"
  echo "    installed: $dest"
}

if [[ $EUID -ne 0 ]] && (( ! DRY_RUN )); then
  echo "Please run as root: sudo $0 $*" >&2
  exit 1
fi

# ------------------------------------------------------------------ uninstall
if (( UNINSTALL )); then
  log "Uninstalling"
  run rm -f /etc/cron.d/devops-optimization
  run rm -f /etc/logrotate.d/devops-optimization
  run rm -f /etc/sysctl.d/99-devops-tuning.conf
  run rm -f /etc/security/limits.d/99-nofile.conf
  if [[ -f /etc/ssh/sshd_config.d/01-hardening.conf ]]; then
    run rm -f /etc/ssh/sshd_config.d/01-hardening.conf
    run systemctl reload ssh 2>/dev/null || run systemctl reload sshd 2>/dev/null || true
  fi
  run rm -rf "$PREFIX"
  run sysctl --system >/dev/null
  log "Done. Kept: $ETC_DIR (your settings), $LOG_DIR, backups, docker/fail2ban configs."
  exit 0
fi

# ------------------------------------------------------------------ packages
if (( INSTALL_PKGS )); then
  log "Installing packages"
  if have apt-get; then
    run apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      fail2ban python3-systemd unattended-upgrades zram-tools lsof sysstat curl
    run dpkg-reconfigure -f noninteractive unattended-upgrades
  elif have dnf; then
    run dnf install -y epel-release || true
    run dnf install -y fail2ban dnf-automatic lsof sysstat curl
    run systemctl enable --now dnf-automatic.timer
  else
    warn "Unsupported package manager - install fail2ban/lsof/sysstat manually"
  fi
fi

# ------------------------------------------------------------------ scripts
log "Installing scripts to $PREFIX/scripts"
for f in "$REPO_DIR"/scripts/*.sh; do
  install_file "$f" "$PREFIX/scripts/$(basename "$f")" 0755
done
run mkdir -p "$LOG_DIR" "$ETC_DIR"

if [[ ! -f "$ETC_DIR/alert.env" ]]; then
  install_file "$REPO_DIR/configs/alert.env.example" "$ETC_DIR/alert.env" 0600
  echo "    -> edit $ETC_DIR/alert.env to add Slack/Telegram alerts"
fi

# ------------------------------------------------------------------ sysctl + limits
log "Applying kernel/network tuning"
install_file "$REPO_DIR/configs/sysctl/99-devops-tuning.conf" /etc/sysctl.d/99-devops-tuning.conf
run sysctl --system >/dev/null
install_file "$REPO_DIR/configs/limits/99-nofile.conf" /etc/security/limits.d/99-nofile.conf

# ------------------------------------------------------------------ cron + logrotate
log "Scheduling jobs (cron) and log rotation"
install_file "$REPO_DIR/configs/cron/devops-optimization" /etc/cron.d/devops-optimization 0644
install_file "$REPO_DIR/configs/logrotate/devops-optimization" /etc/logrotate.d/devops-optimization 0644

# ------------------------------------------------------------------ docker
if (( ! SKIP_DOCKER )) && have docker; then
  log "Docker daemon config"
  if [[ -f /etc/docker/daemon.json ]] && ! cmp -s "$REPO_DIR/configs/docker/daemon.json" /etc/docker/daemon.json; then
    warn "/etc/docker/daemon.json already exists - not overwriting. Merge settings from configs/docker/daemon.json manually."
  elif docker info 2>/dev/null | grep -q 'Swarm: active'; then
    warn "Swarm mode active - live-restore is not supported; skipping daemon.json"
  else
    install_file "$REPO_DIR/configs/docker/daemon.json" /etc/docker/daemon.json
    warn "Docker not restarted automatically. Apply in a maintenance window: sudo systemctl restart docker"
    echo "    (log limits apply to NEW containers; recreate existing ones with docker compose up -d --force-recreate)"
  fi
fi

# ------------------------------------------------------------------ fail2ban
if have fail2ban-client; then
  log "fail2ban"
  if [[ ! -f /etc/fail2ban/jail.local ]]; then
    install_file "$REPO_DIR/configs/fail2ban/jail.local" /etc/fail2ban/jail.local
  else
    echo "    /etc/fail2ban/jail.local exists - left as is"
  fi
  run systemctl enable --now fail2ban
  run systemctl restart fail2ban
fi

# ------------------------------------------------------------------ ssh
if (( SSH_HARDEN )); then
  log "SSH hardening"
  KEYS_FOUND=$(find /root/.ssh /home/*/.ssh -name authorized_keys -size +0 2>/dev/null | wc -l)
  if (( KEYS_FOUND == 0 )); then
    warn "No non-empty authorized_keys found - refusing to disable password login (you would be locked out)."
  else
    install_file "$REPO_DIR/configs/ssh/01-hardening.conf" /etc/ssh/sshd_config.d/01-hardening.conf
    if (( ! DRY_RUN )); then
      if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        warn "/etc/ssh/sshd_config has no Include for sshd_config.d - drop-in will not be read"
      fi
      if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
        log "SSH reloaded. KEEP THIS SESSION OPEN and test a new SSH login before logging out."
      else
        warn "sshd config test failed - rolling back"
        rm -f /etc/ssh/sshd_config.d/01-hardening.conf
      fi
    fi
  fi
fi

log "Installation complete"
cat <<EOF

Next steps:
  1. Run a health report:     sudo $PREFIX/scripts/health_check.sh
  2. Run a security audit:    sudo $PREFIX/scripts/security_audit.sh
  3. Add alert webhooks:      sudo nano $ETC_DIR/alert.env
  4. Test alerts:             sudo $PREFIX/scripts/system_alert.sh --test
  5. Logs:                    $LOG_DIR/
EOF
