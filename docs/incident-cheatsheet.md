# Linux Incident Cheatsheet (DevOps / SRE)

Copy-paste commands for the first 5 minutes of an incident. Start with:

```bash
sudo /opt/devops-optimization/scripts/health_check.sh | less
```

---

## 1. High CPU / load

```bash
uptime                                  # load vs. number of cores (nproc)
top -o %CPU                             # press 1 for per-core, H for threads
ps -eo pid,user,comm,%cpu --sort=-%cpu | head
mpstat -P ALL 1 3                       # per-core usage (sysstat)
pidstat 1 5                             # which process, over time
vmstat 1 5                              # r = run queue, wa = IO wait, st = cloud steal
```

High `wa` -> disk is the bottleneck (see section 3). High `st` on EC2 -> noisy neighbour / burstable (t3) credits exhausted.

## 2. Memory / OOM

```bash
free -h                                 # look at "available", not "free"
ps -eo pid,comm,%mem,rss --sort=-%mem | head
journalctl -k | grep -i -E 'oom|killed process'   # was something OOM-killed?
cat /proc/pressure/memory               # PSI: memory stall time
smem -tk 2>/dev/null | tail             # real per-process usage (if installed)
```

## 3. Disk full / slow disk

```bash
df -hT                                  # which filesystem is full
df -i                                   # inodes full? (millions of tiny files)
sudo du -xh --max-depth=1 / | sort -rh | head
sudo ncdu -x /                          # interactive (apt install ncdu)
sudo lsof -nP +L1                       # DELETED files still held open -> restart that process
sudo journalctl --disk-usage
docker system df                        # images / containers / volumes / build cache
iostat -xz 1 3                          # %util near 100 = saturated disk
iotop -o                                # who is doing the IO
```

Quick space recovery (safe):

```bash
sudo journalctl --vacuum-size=500M
sudo /opt/devops-optimization/scripts/cleanup.sh --dry-run   # preview, then run without --dry-run
sudo truncate -s 0 /var/log/<huge-live-log>.log              # instead of rm on an open file
```

## 4. Network

```bash
ss -tulpn                               # what is listening, which process
ss -s                                   # socket summary (TIME_WAIT storms)
ss -tan state established | wc -l
curl -sv -o /dev/null https://example.com          # DNS + TLS + timing
curl -o /dev/null -s -w '%{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total}\n' https://example.com
dig +short example.com; resolvectl status
mtr -rwc 20 example.com                 # where packets are lost
sudo tcpdump -i any port 443 -nn -c 50
```

## 5. Services & logs

```bash
systemctl --failed
systemctl status <svc> --no-pager -l
journalctl -u <svc> -n 200 --no-pager
journalctl -u <svc> -f                  # follow
journalctl -p err -S "1 hour ago"
journalctl -b -1 -p err                 # errors from previous boot (after crash/reboot)
```

## 6. Docker

```bash
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker stats --no-stream
docker logs --tail 200 -f <container>
docker inspect <container> --format '{{.State.OOMKilled}} {{.RestartCount}}'
docker exec -it <container> sh
docker compose ps && docker compose logs --tail 100
```

## 7. SSH / access

```bash
sudo fail2ban-client status sshd        # banned IPs
sudo fail2ban-client set sshd unbanip <ip>
last -n 20; lastb -n 20                 # successful / failed logins
sudo sshd -t                            # validate config BEFORE reloading
```

## 8. AWS EC2 specifics

```bash
curl -s -H "X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-type
aws ec2 describe-instance-status --instance-ids <id>
aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUCreditBalance \
  --dimensions Name=InstanceId,Value=<id> --start-time $(date -u -d '-3 hours' +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 300 --statistics Average
sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1   # after enlarging EBS (xfs: xfs_growfs /)
```

## Post-incident checklist

- [ ] Root cause written down (what, why, why it was not caught earlier)
- [ ] Alert threshold or new check added in `system_alert.sh` / `alert.env`
- [ ] Runbook / this cheatsheet updated
- [ ] Fix automated (script, cron, config) instead of manual
