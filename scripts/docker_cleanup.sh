#!/usr/bin/env bash
# Weekly Docker cleanup. Removes unused containers, images, networks and build cache
# older than DOCKER_PRUNE_UNTIL. Named volumes are never removed.
# Usage: sudo ./docker_cleanup.sh
set -euo pipefail

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Docker not installed or not running - skipping"
  exit 0
fi

UNTIL="${DOCKER_PRUNE_UNTIL:-168h}"

echo "===== Docker cleanup: $(date '+%F %T') ====="
echo "--- Before ---"
docker system df

docker container prune -f --filter "until=$UNTIL"
docker image prune -af --filter "until=$UNTIL"
docker network prune -f --filter "until=$UNTIL"
docker builder prune -af --filter "until=$UNTIL"

# Opt-in only: anonymous (unnamed) volumes not used by any container
if [[ "${PRUNE_ANON_VOLUMES:-0}" == "1" ]]; then
  docker volume prune -f
fi

echo "--- After ---"
docker system df
