# Linux Server Performance & DevOps Hardening Guide

> **Author:** Girish Burade  
> **Role:** DevOps / Cloud Engineer  
> **Purpose:** Make Linux servers fast, stable, secure, and production‑ready  
> **Use case:** STG / DEV / EC2 / Personal Servers

---

## 1. Overview
This document explains **end‑to‑end system optimization** performed on a Linux server using DevOps best practices.  
It covers cleanup, performance tuning, Docker optimization, monitoring, and hardening.

This setup is suitable for:
- Staging & development servers
- Cloud VMs (AWS EC2 / GCP / Azure)
- Personal Linux systems

---

## 2. Disk & Log Cleanup Automation

### 2.1 Cleanup Script
**Path:** `/opt/scripts/cleanup.sh`

```bash
#!/bin/bash

echo "===== Cleanup Started ====="
date

# Clean old system logs (older than 7 days)
find /var/log -type f -name "*.log" -mtime +7 -exec truncate -s 0 {} \;

# Clean journal logs (keep last 7 days)
journalctl --vacuum-time=7d

# Clean temporary files
rm -rf /tmp/*
rm -rf /var/tmp/*

# Docker cleanup
docker system prune -af --volumes

# Disk usage check
df -h /

echo "===== Cleanup Completed ====="
date
```

### 2.2 Schedule via Cron
```bash
sudo crontab -e
```

```bash
0 2 * * * /opt/scripts/cleanup.sh >> /var/log/cleanup.log 2>&1
```

---

## 3. Memory & Performance Optimization

### 3.1 Swappiness Tuning
Reduce aggressive swap usage.

```bash
sudo sysctl vm.swappiness=10
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 3.2 VFS Cache Optimization
Improves file access speed.

```bash
echo "vm.vfs_cache_pressure=50" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## 4. ZRAM (Compressed Memory)

ZRAM uses compressed RAM instead of disk swap.

```bash
sudo apt update
sudo apt install -y zram-tools
swapon --show
systemctl status zramswap
```

---

## 5. Docker Optimization

### 5.1 Limit Docker Log Size
**File:** `/etc/docker/daemon.json`

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
```

```bash
sudo systemctl restart docker
```

### 5.2 Weekly Docker Cleanup
**Script:** `/opt/scripts/docker_cleanup.sh`

```bash
#!/bin/bash
docker system prune -af
```

```bash
sudo chmod +x /opt/scripts/docker_cleanup.sh
sudo crontab -e
```

```bash
0 3 * * 0 /opt/scripts/docker_cleanup.sh >> /var/log/docker_cleanup.log 2>&1
```

---

## 6. Auto Monitoring & Alerts

### 6.1 Alert Script
**Path:** `/opt/scripts/system_alert.sh`

```bash
#!/bin/bash

HOSTNAME=$(hostname)
DATE=$(date)

DISK_THRESHOLD=80
MEM_THRESHOLD=80
CPU_THRESHOLD=90

DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
MEM_USAGE=$(free | awk '/Mem/ {printf("%.0f"), $3/$2 * 100}')
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')

LOG_FILE="/var/log/system_alert.log"

if [ "$DISK_USAGE" -ge "$DISK_THRESHOLD" ]; then
  echo "$DATE | $HOSTNAME | Disk usage: ${DISK_USAGE}%" >> $LOG_FILE
fi

if [ "$MEM_USAGE" -ge "$MEM_THRESHOLD" ]; then
  echo "$DATE | $HOSTNAME | Memory usage: ${MEM_USAGE}%" >> $LOG_FILE
fi

if [ "${CPU_USAGE%.*}" -ge "$CPU_THRESHOLD" ]; then
  echo "$DATE | $HOSTNAME | CPU usage: ${CPU_USAGE}%" >> $LOG_FILE
fi
```

### 6.2 Schedule Alerts
```bash
*/5 * * * * /opt/scripts/system_alert.sh
```

---

## 7. Production‑Safe Hardening

### 7.1 Automatic Security Updates
```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure unattended-upgrades
```

### 7.2 Increase Open File Limits
```bash
echo "* soft nofile 100000" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 100000" | sudo tee -a /etc/security/limits.conf
```

### 7.3 Network Performance Tuning
```bash
sudo tee -a /etc/sysctl.conf <<EOF
net.core.somaxconn=65535
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_syn_backlog=4096
EOF

sudo sysctl -p
```

### 7.4 Fail2Ban
```bash
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

---

## 8. Final Outcome

✅ Faster system response  
✅ Stable memory usage  
✅ Controlled disk growth  
✅ Docker‑safe operations  
✅ Proactive monitoring  
✅ Production‑ready hardening

---

## 9. GitHub Structure (Recommended)
```
linux-devops-optimization/
├── README.md
├── scripts/
│   ├── cleanup.sh
│   ├── docker_cleanup.sh
│   └── system_alert.sh
```

---

## 10. LinkedIn Article Tip
**Suggested Title:**  
> How I Optimized a Linux Server for Performance, Stability, and DevOps Best Practices

**Tags:**  
#DevOps #Linux #Docker #Cloud #AWS #SRE #PerformanceOptimization

---

*This document can be directly used as a README.md in VS Code and published as a technical article on LinkedIn.*

