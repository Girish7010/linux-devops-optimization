# linux-devops-optimization

[![lint](https://github.com/Girish7010/linux-devops-optimization/actions/workflows/lint.yml/badge.svg)](https://github.com/Girish7010/linux-devops-optimization/actions/workflows/lint.yml)

**Production-ready Linux server optimization, monitoring and hardening toolkit — installable with one command.**

Author: **Girish Burade** — DevOps / Cloud Engineer
Use case: STG / DEV / PROD servers, AWS EC2, GCP, Azure VMs, personal Linux servers (Ubuntu/Debian, RHEL/Rocky/Amazon Linux)

> Full write-up of the approach: [Linux Server Performance & DevOps Hardening Guide](linux_server_performance_dev_ops_hardening_guide.md)

---

## What you get

| Area | Tool | What it does |
|---|---|---|
| Install | `install.sh` | One command, idempotent, `--dry-run`, backs up every file it replaces, `--uninstall` |
| Health | `scripts/health_check.sh` | Read-only incident report: CPU, memory, disk, inodes, deleted-but-open files, ports, failed units, OOM kills, Docker, pending updates |
| Alerts | `scripts/system_alert.sh` | Disk (all mounts), inodes, memory, CPU, load, failed systemd units → **Slack / Telegram**, with cooldown + recovery messages |
| Security | `scripts/security_audit.sh` | PASS/WARN/FAIL audit: SSH, firewall, fail2ban, auto-updates, UID 0, empty passwords, sudo NOPASSWD, open ports, sysctl, Docker — with a score |
| Backup | `scripts/backup.sh` | `tar.gz` + SHA256 + verification, retention, optional upload to **S3** |
| Cleanup | `scripts/cleanup.sh` | Safe cleanup of journal, rotated logs, old temp files, apt/dnf cache, Docker, old snaps (`--dry-run` supported) |
| Docker | `scripts/docker_cleanup.sh` | Weekly prune of old images/containers/build cache — **never deletes named volumes** |
| Kernel | `configs/sysctl/99-devops-tuning.conf` | Memory, file-handle, TCP performance and network hardening (drop-in, easy rollback) |
| SSH | `configs/ssh/01-hardening.conf` | Key-only login, no root password login, MaxAuthTries 3 (opt-in, validated before reload) |
| Brute force | `configs/fail2ban/jail.local` | sshd jail with incremental bans |
| Docker daemon | `configs/docker/daemon.json` | Log rotation (50MB x 3), live-restore, ulimits |
| Scheduling | `configs/cron/`, `configs/logrotate/` | Cron jobs for all scripts + rotation of their logs |
| Runbook | `docs/incident-cheatsheet.md` | Copy-paste commands for CPU, memory, disk, network, Docker, SSH, EC2 incidents |
| CI | `.github/workflows/lint.yml` | ShellCheck + syntax check + installer dry-run on every push |

## Repository structure

```text
linux-devops-optimization/
├── install.sh                         # one-command installer
├── scripts/
│   ├── health_check.sh                # read-only health report
│   ├── system_alert.sh                # threshold alerts -> Slack/Telegram
│   ├── security_audit.sh              # hardening audit with score
│   ├── backup.sh                      # backups with retention + S3
│   ├── cleanup.sh                     # safe disk/log cleanup
│   └── docker_cleanup.sh              # weekly Docker prune (volumes safe)
├── configs/
│   ├── alert.env.example              # thresholds + webhook settings
│   ├── sysctl/99-devops-tuning.conf
│   ├── limits/99-nofile.conf
│   ├── ssh/01-hardening.conf
│   ├── fail2ban/jail.local
│   ├── docker/daemon.json
│   ├── cron/devops-optimization
│   └── logrotate/devops-optimization
├── docs/
│   └── incident-cheatsheet.md
└── linux_server_performance_dev_ops_hardening_guide.md
```

## Quick start

```bash
git clone https://github.com/Girish7010/linux-devops-optimization.git
cd linux-devops-optimization

sudo bash install.sh --dry-run              # 1. preview every change
sudo bash install.sh --install-packages     # 2. install (adds fail2ban, unattended-upgrades, zram, lsof, sysstat)

sudo /opt/devops-optimization/scripts/health_check.sh
sudo /opt/devops-optimization/scripts/security_audit.sh
```

Optional SSH hardening (only after confirming you can log in with an SSH key):

```bash
sudo bash install.sh --with-ssh-hardening
# keep your current session open and test a NEW ssh login before closing it
```

### Installer options

| Flag | Effect |
|---|---|
| `--dry-run` | Print what would change, change nothing |
| `--install-packages` | Install fail2ban, unattended-upgrades / dnf-automatic, zram-tools, lsof, sysstat, curl |
| `--with-ssh-hardening` | Apply `01-hardening.conf`; refuses if no `authorized_keys` exist, rolls back if `sshd -t` fails |
| `--skip-docker` | Don't touch `/etc/docker/daemon.json` |
| `--uninstall` | Remove scripts, cron, sysctl, limits, ssh drop-in (keeps your settings, logs and backups) |

## Alerts to Slack / Telegram

```bash
sudo nano /etc/devops-optimization/alert.env
# SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
# or TELEGRAM_BOT_TOKEN=...  TELEGRAM_CHAT_ID=...

sudo /opt/devops-optimization/scripts/system_alert.sh --test
```

Example message:

```text
[ALERT] 2026-11-26 14:05:01 | stg-api-01 | Disk usage on / is 91% (threshold 80%)
[RESOLVED] 2026-11-26 14:40:01 | stg-api-01 | Disk usage on / back to 62%
```

## Backups to S3

```bash
sudo tee /etc/devops-optimization/backup.env <<'EOF'
BACKUP_PATHS="/etc /opt/app /var/www"
RETENTION_DAYS=7
S3_BUCKET=s3://my-company-backups/servers
EOF
sudo /opt/devops-optimization/scripts/backup.sh
```

On EC2 give the instance an IAM role with `s3:PutObject` on that bucket instead of storing access keys. Add an S3 lifecycle rule for long-term retention.

## Schedule (installed to `/etc/cron.d/devops-optimization`)

| When | Job |
|---|---|
| every 5 min | `system_alert.sh` |
| daily 01:30 | `backup.sh` |
| daily 02:00 | `cleanup.sh` |
| Sunday 03:00 | `docker_cleanup.sh` |

Logs: `/var/log/devops-optimization/` (rotated weekly).

## Safety notes

- `cleanup.sh` only deletes **rotated** logs and temp files **not accessed for 3+ days**. It does not `rm -rf /tmp/*` (that can break running apps) and does not prune Docker volumes (that deletes databases).
- Kernel tuning is a drop-in under `/etc/sysctl.d/` instead of appending to `/etc/sysctl.conf`, so re-running never creates duplicates. Roll back: `sudo rm /etc/sysctl.d/99-devops-tuning.conf && sudo sysctl --system`.
- `limits.d` does not apply to systemd services — set `LimitNOFILE=100000` with `sudo systemctl edit <service>`.
- `live-restore` in `daemon.json` is incompatible with Docker Swarm; the installer skips it when Swarm is active.
- Test on a staging server first. Every replaced file is backed up as `*.bak-<timestamp>`.

## Roadmap / ideas

- [ ] Ansible role for running this across a fleet
- [ ] Terraform / EC2 user-data example that installs this at boot
- [ ] Prometheus `node_exporter` + Grafana dashboard option
- [ ] CloudWatch agent config for memory & disk metrics on EC2

## LinkedIn

Suggested title: *How I Optimized a Linux Server for Performance, Stability, and DevOps Best Practices*
Tags: `#DevOps #Linux #Docker #Cloud #AWS #SRE #PerformanceOptimization`

## Contributing

Issues and PRs welcome — run `shellcheck install.sh scripts/*.sh` before opening one.
