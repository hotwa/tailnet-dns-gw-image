#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-digest.sh [--dry-run] sha256:<64-hex-digest>

Required environment:
  TAILNET_DNS_REGISTRY_IMAGE

Write gate:
  TAILNET_DNS_DEPLOY_CONFIRMED=1   Required unless --dry-run is used

Optional environment:
  TAILNET_DNS_STACK_DIR            Default: /opt/gateway-stack
  TAILNET_DNS_COMPOSE_FILE         Default: $TAILNET_DNS_STACK_DIR/docker-compose.yml
  TAILNET_DNS_LOCAL_IMAGE          Current Compose image tag
  TAILNET_DNS_BACKUP_DIR           Default: $TAILNET_DNS_STACK_DIR/backups/registry-tailnet-dns-gw
  TAILNET_DNS_STATE_DIR            Default: /var/lib/tailnet-dns-gw-registry-deploy
  TAILNET_DNS_EXPECTED_IP          Default: preserve the current Tailnet IPv4
EOF
}

dry_run=0
if [ "${1:-}" = --dry-run ]; then
  dry_run=1
  shift
fi

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
digest=$1
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "invalid image digest: $digest" >&2
  exit 2
}

image=${TAILNET_DNS_REGISTRY_IMAGE:-}
[ -n "$image" ] || { echo 'TAILNET_DNS_REGISTRY_IMAGE is required' >&2; exit 2; }
[[ "$image" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+$ ]] || {
  echo "TAILNET_DNS_REGISTRY_IMAGE must be a lowercase, untagged image: $image" >&2
  exit 2
}

stack_dir=${TAILNET_DNS_STACK_DIR:-/opt/gateway-stack}
compose_file=${TAILNET_DNS_COMPOSE_FILE:-$stack_dir/docker-compose.yml}
local_current=${TAILNET_DNS_LOCAL_IMAGE:-gateway-stack/tailnet-dns-gw:1.102.2-adguard-v0.107.78-integrated-relay1}
local_rollback=${TAILNET_DNS_ROLLBACK_IMAGE:-gateway-stack/tailnet-dns-gw:registry-rollback}
backup_root=${TAILNET_DNS_BACKUP_DIR:-$stack_dir/backups/registry-tailnet-dns-gw}
state_dir=${TAILNET_DNS_STATE_DIR:-/var/lib/tailnet-dns-gw-registry-deploy}
attempts=${TAILNET_DNS_HEALTH_ATTEMPTS:-30}
interval=${TAILNET_DNS_HEALTH_INTERVAL_SECONDS:-5}
lock_file=${TAILNET_DNS_LOCK_FILE:-/run/lock/tailnet-dns-gw-registry-deploy.lock}
remote_ref="$image@$digest"
compose=(docker compose -f "$compose_file")

case "$attempts" in *[!0-9]*|'') echo 'TAILNET_DNS_HEALTH_ATTEMPTS must be an integer' >&2; exit 2 ;; esac
case "$interval" in *[!0-9]*|'') echo 'TAILNET_DNS_HEALTH_INTERVAL_SECONDS must be an integer' >&2; exit 2 ;; esac
[ "$attempts" -gt 0 ] || { echo 'TAILNET_DNS_HEALTH_ATTEMPTS must be greater than zero' >&2; exit 2; }
[ -d "$stack_dir" ] || { echo "stack directory not found: $stack_dir" >&2; exit 1; }
[ -f "$compose_file" ] || { echo "compose file not found: $compose_file" >&2; exit 1; }

container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' tailscale-gw 2>/dev/null || true
}

tailnet_ip() {
  docker exec tailscale-gw tailscale ip -4 2>/dev/null | awk 'NR == 1 {print $1}'
}

wait_for_service() {
  local remaining=$attempts status
  while [ "$remaining" -gt 0 ]; do
    status=$(container_health)
    if [ "$status" = healthy ]; then
      return 0
    fi
    if [ "$status" = exited ] || [ "$status" = dead ]; then
      return 1
    fi
    remaining=$((remaining - 1))
    [ "$remaining" -gt 0 ] && sleep "$interval"
  done
  return 1
}

validate_data_plane() {
  local expected_ip=$1 expected_ts=$2 expected_agh=$3 actual_ip actual_ts actual_agh
  wait_for_service || return 1
  actual_ip=$(tailnet_ip)
  [ "$actual_ip" = "$expected_ip" ] || {
    echo "Tailnet IPv4 changed: expected=$expected_ip actual=${actual_ip:-missing}" >&2
    return 1
  }
  actual_ts=$(docker exec tailscale-gw tailscale version | awk 'NR == 1 {print $1}')
  actual_agh=$(docker exec tailscale-gw /opt/adguardhome/AdGuardHome --version | awk '{print $NF}')
  [ "v$actual_ts" = "$expected_ts" ] || {
    echo "unexpected Tailscale version: expected=$expected_ts actual=$actual_ts" >&2
    return 1
  }
  [ "$actual_agh" = "$expected_agh" ] || {
    echo "unexpected AdGuard Home version: expected=$expected_agh actual=$actual_agh" >&2
    return 1
  }
  "$stack_dir/check-dns-stack.sh" >/dev/null
  curl --fail --silent --show-error --max-time 10 https://headscale.jmsu.top/health >/dev/null
  curl --fail --silent --show-error --max-time 10 https://headplane.jmsu.top/admin >/dev/null
}

current_health=$(container_health)
[ "$current_health" = healthy ] || {
  echo "refusing deployment because tailscale-gw is not healthy: ${current_health:-unknown}" >&2
  exit 1
}
current_ip=$(tailnet_ip)
[ -n "$current_ip" ] || { echo 'unable to read current Tailnet IPv4' >&2; exit 1; }
current_ts=$(docker exec tailscale-gw tailscale version | awk 'NR == 1 {print $1}')
current_agh=$(docker exec tailscale-gw /opt/adguardhome/AdGuardHome --version | awk '{print $NF}')
expected_ip=${TAILNET_DNS_EXPECTED_IP:-$current_ip}
[ "$current_ip" = "$expected_ip" ] || {
  echo "current Tailnet IPv4 does not match configured expectation: $current_ip != $expected_ip" >&2
  exit 1
}

if [ "$dry_run" -eq 1 ]; then
  printf 'dry-run: would deploy %s\n' "$remote_ref"
  printf 'dry-run: stack=%s local_image=%s expected_ip=%s\n' "$stack_dir" "$local_current" "$expected_ip"
  exit 0
fi

[ "${TAILNET_DNS_DEPLOY_CONFIRMED:-0}" = 1 ] || {
  echo 'set TAILNET_DNS_DEPLOY_CONFIRMED=1 after reviewing the digest and rollback path' >&2
  exit 2
}

mkdir -p "$(dirname "$lock_file")"
exec 9>"$lock_file"
flock -n 9 || { echo 'another Tailnet DNS Gateway deployment is running' >&2; exit 3; }

echo "pulling immutable candidate: $remote_ref"
docker pull "$remote_ref"

remote_arch=$(docker image inspect --format '{{.Architecture}}' "$remote_ref")
remote_os=$(docker image inspect --format '{{.Os}}' "$remote_ref")
target_ts=$(docker image inspect --format '{{index .Config.Labels "io.jmsu.tailnet-dns-gw.tailscale-version"}}' "$remote_ref")
target_agh=$(docker image inspect --format '{{index .Config.Labels "io.jmsu.tailnet-dns-gw.adguardhome-version"}}' "$remote_ref")
[ "$remote_arch" = amd64 ] || { echo "unexpected image architecture: $remote_arch" >&2; exit 1; }
[ "$remote_os" = linux ] || { echo "unexpected image OS: $remote_os" >&2; exit 1; }
[[ "$target_ts" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'missing Tailscale version label' >&2; exit 1; }
[[ "$target_agh" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'missing AdGuard Home version label' >&2; exit 1; }
for version_pair in "${current_ts}:${target_ts#v}:Tailscale" "${current_agh#v}:${target_agh#v}:AdGuardHome"; do
  current_version=${version_pair%%:*}
  remainder=${version_pair#*:}
  target_version=${remainder%%:*}
  component=${remainder##*:}
  first=$(printf '%s\n%s\n' "$current_version" "$target_version" | sort -V | head -n1)
  [ "$first" = "$current_version" ] || {
    echo "refusing $component downgrade: current=$current_version target=$target_version" >&2
    exit 1
  }
done

umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
short_digest=${digest#sha256:}
short_digest=${short_digest:0:12}
backup_dir="$backup_root/$stamp-before-$short_digest"
mkdir -p "$backup_dir" "$state_dir"
cp -a "$compose_file" "$backup_dir/docker-compose.yml"
cp -a "$stack_dir/adguardhome/conf/AdGuardHome.yaml" "$backup_dir/AdGuardHome-main.yaml"
cp -a "$stack_dir/adguardhome-tailnet/conf/AdGuardHome.yaml" "$backup_dir/AdGuardHome-tailnet.yaml"
cp -a "$stack_dir/tailnet-dns-gw/Dockerfile" "$backup_dir/Dockerfile"
cp -a "$stack_dir/tailnet-dns-gw/entrypoint.sh" "$backup_dir/entrypoint.sh"
cp -a "$stack_dir/tailnet-dns-gw/healthcheck.sh" "$backup_dir/healthcheck.sh"
tar -C "$stack_dir/tailscale-gw" -cpf "$backup_dir/tailscale-state.tar" state
docker image inspect "$local_current" >"$backup_dir/old-image-inspect.json"

docker image tag "$local_current" "$local_rollback"
docker image tag "$remote_ref" "$local_current"

echo "recreating tailscale-gw from $remote_ref"
if "${compose[@]}" up -d --no-deps --force-recreate tailscale-gw &&
   validate_data_plane "$expected_ip" "$target_ts" "$target_agh"; then
  printf '%s\n' "$digest" >"$state_dir/last-successful-digest"
  printf '%s\n' "$target_ts" >"$state_dir/last-tailscale-version"
  printf '%s\n' "$target_agh" >"$state_dir/last-adguardhome-version"
  chmod 600 "$state_dir"/*
  printf 'deployment healthy: digest=%s tailscale=%s adguardhome=%s backup=%s\n' \
    "$digest" "$target_ts" "$target_agh" "$backup_dir"
  exit 0
fi

echo 'candidate failed checks; restoring rollback image' >&2
docker image tag "$local_rollback" "$local_current"
if "${compose[@]}" up -d --no-deps --force-recreate tailscale-gw && wait_for_service &&
   [ "$(tailnet_ip)" = "$expected_ip" ]; then
  echo "rollback healthy; failed digest=$digest backup=$backup_dir" >&2
  exit 1
fi

echo "rollback also failed; manual recovery required; backup=$backup_dir" >&2
exit 2
