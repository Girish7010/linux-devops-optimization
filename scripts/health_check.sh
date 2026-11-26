#!/usr/bin/env bash
# One-shot, read-only server health report. Safe to run anytime (e.g. first thing in an incident).
# Usage: sudo ./health_check.sh            # print to screen
#        sudo ./health_check.sh > report.txt
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n==================== %s ====================\n' "$1"; }

section "SYSTEM"
echo "Host     : $(hostname)"
[[ -r /etc/os-release ]] && echo "OS       : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "Kernel   : $(uname -r)"
echo "Uptime   : $(uptime -p 2>/dev/null || uptime)"
echo "Load avg : $(cut -d' ' -f1-3 /proc/loadavg)  (cores: $(nproc))"
echo "Time     : $(date '+%F %T %Z')"
if have timedatectl; then
  echo "NTP sync : $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
fi
[[ -f /var/run/reboot-required ]] && echo "!! Reboot required (pending kernel/library updates)"

section "CPU / MEMORY"
free -h
echo
swapon --show 2>/dev/null || true
if have vmstat; then
  echo
  vmstat 1 3
fi

section "TOP 5 PROCESSES BY CPU"
ps -eo pid,user,comm,%cpu,%mem --sort=-%cpu | head -n 6

section "TOP 5 PROCESSES BY MEMORY"
ps -eo pid,user,comm,%cpu,%mem,rss --sort=-%mem | head -n 6

section "DISK USAGE"
df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay

section "INODE USAGE"
df -i -x tmpfs -x devtmpfs -x squashfs -x overlay

section "BIGGEST DIRECTORIES IN /var"
du -xh --max-depth=1 /var 2>/dev/null | sort -rh | head -n 8

section "DELETED FILES STILL HELD OPEN (hidden disk usage)"
if have lsof; then
  lsof -nP +L1 2>/dev/null | awk 'NR==1 || $7 > 104857600' | head -n 10
  echo "(showing files > 100MB; restart the owning process to free the space)"
else
  echo "lsof not installed"
fi

section "LISTENING PORTS"
if have ss; then ss -tulpn 2>/dev/null; else netstat -tulpn 2>/dev/null; fi

section "FAILED SYSTEMD UNITS"
if have systemctl; then systemctl --failed --no-pager; fi

section "RECENT ERRORS (journal, last 1h, priority err+)"
if have journalctl; then
  journalctl -p err --since "1 hour ago" --no-pager 2>/dev/null | tail -n 20
fi

section "OOM KILLER EVENTS (last 24h)"
if have journalctl; then
  journalctl -k --since "24 hours ago" --no-pager 2>/dev/null | grep -i -E 'out of memory|oom-kill' | tail -n 5 || echo "none"
fi

section "DOCKER"
if have docker && docker info >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  echo
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
  echo
  docker system df
else
  echo "Docker not installed or not running"
fi

section "PENDING UPDATES"
if have apt-get; then
  apt-get -s upgrade 2>/dev/null | grep -c '^Inst' | xargs echo "apt packages upgradable:"
elif have dnf; then
  dnf -q check-update 2>/dev/null | grep -c . | xargs echo "dnf packages upgradable:"
fi

section "LAST LOGINS"
last -n 5 2>/dev/null || true

echo
echo "Report finished: $(date '+%F %T')"
