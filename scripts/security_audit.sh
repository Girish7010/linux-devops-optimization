#!/usr/bin/env bash
# Read-only security audit. Prints PASS / WARN / FAIL for common hardening checks
# and a final score. Changes nothing on the server.
# Usage: sudo ./security_audit.sh
set -uo pipefail

PASS=0; WARN=0; FAIL=0
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
[[ -t 1 ]] || { GREEN=''; YELLOW=''; RED=''; NC=''; }

pass() { printf "${GREEN}[PASS]${NC} %s\n" "$1"; PASS=$((PASS+1)); }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; WARN=$((WARN+1)); }
fail() { printf "${RED}[FAIL]${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -ne 0 ]]; then
  echo "Note: run with sudo for complete results." >&2
fi

echo "== SSH =="
if have sshd; then
  SSHD_CFG=$(sshd -T 2>/dev/null)
  get() { echo "$SSHD_CFG" | awk -v k="$1" '$1==k {print $2; exit}'; }
  case "$(get permitrootlogin)" in
    no|prohibit-password|without-password) pass "Root login with password disabled ($(get permitrootlogin))" ;;
    "") warn "Could not read sshd config (run with sudo)" ;;
    *) fail "PermitRootLogin is '$(get permitrootlogin)'" ;;
  esac
  [[ "$(get passwordauthentication)" == "no" ]] && pass "Password authentication disabled" || fail "Password authentication is enabled (use SSH keys)"
  MAX_TRIES=$(get maxauthtries)
  [[ -n "$MAX_TRIES" && "$MAX_TRIES" -le 4 ]] && pass "MaxAuthTries = $MAX_TRIES" || warn "MaxAuthTries = ${MAX_TRIES:-unknown} (recommend <= 4)"
  [[ "$(get x11forwarding)" == "no" ]] && pass "X11 forwarding disabled" || warn "X11 forwarding enabled"
else
  warn "sshd not found"
fi

echo; echo "== Firewall =="
if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  pass "UFW firewall active"
elif have firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q running; then
  pass "firewalld active"
elif have nft && [[ -n "$(nft list ruleset 2>/dev/null)" ]]; then
  pass "nftables ruleset present"
else
  warn "No host firewall detected (OK only if a cloud security group is strictly configured)"
fi

echo; echo "== Brute-force protection =="
if have systemctl && systemctl is-active --quiet fail2ban 2>/dev/null; then
  pass "fail2ban running"
else
  warn "fail2ban not running"
fi

echo; echo "== Updates =="
if [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  pass "Unattended security upgrades enabled"
elif have systemctl && systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null; then
  pass "dnf-automatic enabled"
else
  warn "Automatic security updates not enabled"
fi
[[ -f /var/run/reboot-required ]] && warn "Reboot required to apply updates" || pass "No pending reboot"

echo; echo "== Accounts =="
UID0=$(awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd | paste -sd, -)
[[ -z "$UID0" ]] && pass "Only root has UID 0" || fail "Extra UID 0 accounts: $UID0"
if [[ -r /etc/shadow ]]; then
  EMPTY=$(awk -F: '$2=="" {print $1}' /etc/shadow | paste -sd, -)
  [[ -z "$EMPTY" ]] && pass "No accounts with empty passwords" || fail "Accounts with empty password: $EMPTY"
fi
NOPASSWD=$(grep -rhs 'NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -v '^#' | wc -l)
(( NOPASSWD == 0 )) && pass "No NOPASSWD sudo rules" || warn "$NOPASSWD NOPASSWD sudo rule(s) found (normal on cloud images, review them)"

echo; echo "== Network exposure =="
if have ss; then
  PUBLIC=$(ss -tulnH 2>/dev/null | awk '{print $5}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | paste -sd, -)
  if [[ -z "$PUBLIC" ]]; then
    pass "No services listening on all interfaces"
  else
    warn "Ports open on all interfaces: $PUBLIC (make sure each one is intended)"
  fi
else
  warn "ss not installed (apt install iproute2) - network exposure not checked"
fi

echo; echo "== Kernel / sysctl =="
chk_sysctl() {
  local key="$1" want="$2" got
  got=$(sysctl -n "$key" 2>/dev/null) || { warn "$key not available"; return; }
  [[ "$got" == "$want" ]] && pass "$key = $got" || warn "$key = $got (recommended $want)"
}
chk_sysctl net.ipv4.tcp_syncookies 1
chk_sysctl net.ipv4.conf.all.accept_redirects 0
chk_sysctl net.ipv4.conf.all.send_redirects 0
chk_sysctl kernel.dmesg_restrict 1

echo; echo "== File permissions =="
WW=$(find /etc -xdev -type f -perm -0002 2>/dev/null | head -n 5 | paste -sd, -)
[[ -z "$WW" ]] && pass "No world-writable files in /etc" || fail "World-writable files in /etc: $WW"
[[ "$(stat -c %a /etc/shadow 2>/dev/null)" =~ ^(0|600|640)$ ]] && pass "/etc/shadow permissions OK" || warn "/etc/shadow permissions: $(stat -c %a /etc/shadow 2>/dev/null)"

echo; echo "== Docker =="
if have docker && docker info >/dev/null 2>&1; then
  if [[ -S /var/run/docker.sock ]] && [[ "$(stat -c %a /var/run/docker.sock)" == "660" ]]; then
    pass "docker.sock permissions 660"
  else
    warn "docker.sock permissions: $(stat -c %a /var/run/docker.sock 2>/dev/null)"
  fi
  PRIV=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{.HostConfig.Privileged}}' 2>/dev/null | awk '$2=="true"{print $1}' | paste -sd, -)
  [[ -z "$PRIV" ]] && pass "No privileged containers running" || warn "Privileged containers: $PRIV"
else
  echo "Docker not installed - skipped"
fi

TOTAL=$((PASS+WARN+FAIL))
SCORE=$(( TOTAL > 0 ? PASS * 100 / TOTAL : 0 ))
echo
echo "=============================================="
echo " PASS: $PASS   WARN: $WARN   FAIL: $FAIL   SCORE: $SCORE%"
echo "=============================================="
(( FAIL > 0 )) && exit 2
exit 0
