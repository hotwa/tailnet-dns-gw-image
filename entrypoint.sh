#!/bin/sh
set -eu

TS_SOCKET="${TS_SOCKET:-/run/tailscale/tailscaled.sock}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_PORT="${PORT:-41641}"
ADGUARD_BIN="/opt/adguardhome/AdGuardHome"
ADGUARD_CONF="${ADGUARD_CONF:-/opt/adguardhome/conf/AdGuardHome.yaml}"
ADGUARD_WORK="${ADGUARD_WORK:-/opt/adguardhome/work}"
DNS_RELAY_LISTEN="${DNS_RELAY_LISTEN:-0.0.0.0:5354}"
DNS_RELAY_TARGET="${DNS_RELAY_TARGET:-100.64.0.11:5353}"
DNS_RELAY_IDLE_TIMEOUT="${DNS_RELAY_IDLE_TIMEOUT:-5}"

TAILSCALED_PID=""
ADGUARD_PID=""
DNS_RELAY_UDP_PID=""
DNS_RELAY_TCP_PID=""

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*"
}

shutdown() {
  log "stopping tailnet-dns-gw"
  [ -n "$DNS_RELAY_TCP_PID" ] && kill "$DNS_RELAY_TCP_PID" 2>/dev/null || true
  [ -n "$DNS_RELAY_UDP_PID" ] && kill "$DNS_RELAY_UDP_PID" 2>/dev/null || true
  [ -n "$ADGUARD_PID" ] && kill "$ADGUARD_PID" 2>/dev/null || true
  [ -n "$TAILSCALED_PID" ] && kill "$TAILSCALED_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap shutdown INT TERM

mkdir -p "$(dirname "$TS_SOCKET")" "$TS_STATE_DIR" /opt/adguardhome/conf "$ADGUARD_WORK"

case "$DNS_RELAY_IDLE_TIMEOUT" in
  *[!0-9]*|'') log "invalid DNS_RELAY_IDLE_TIMEOUT: $DNS_RELAY_IDLE_TIMEOUT"; exit 1 ;;
esac
[ "$DNS_RELAY_IDLE_TIMEOUT" -gt 0 ] || { log "DNS_RELAY_IDLE_TIMEOUT must be greater than zero"; exit 1; }

log "starting tailscaled"
tailscaled --state="${TS_STATE_DIR}/tailscaled.state" --socket="$TS_SOCKET" --port="$TS_PORT" &
TAILSCALED_PID="$!"

for i in $(seq 1 60); do
  if tailscale --socket="$TS_SOCKET" status >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    log "tailscaled exited during startup"
    wait "$TAILSCALED_PID" || true
    exit 1
  fi
  if [ "$i" = "60" ]; then
    log "tailscaled socket did not become ready"
    exit 1
  fi
done

if ! tailscale --socket="$TS_SOCKET" ip -4 >/dev/null 2>&1; then
  log "running tailscale up"
  if [ -n "${TS_AUTHKEY:-}" ]; then
    # TS_EXTRA_ARGS is an intentional operator-supplied argument list.
    # shellcheck disable=SC2086
    tailscale --socket="$TS_SOCKET" up ${TS_EXTRA_ARGS:-} --hostname="${TS_HOSTNAME:-ecs-tailscale-gw}" --auth-key="$TS_AUTHKEY"
  else
    # shellcheck disable=SC2086
    tailscale --socket="$TS_SOCKET" up ${TS_EXTRA_ARGS:-} --hostname="${TS_HOSTNAME:-ecs-tailscale-gw}"
  fi
else
  log "tailscale state already authenticated"
fi

for i in $(seq 1 60); do
  if ip4="$(tailscale --socket="$TS_SOCKET" ip -4 2>/dev/null | awk 'NR == 1 {print $1}')" && [ -n "$ip4" ]; then
    log "tailscale IPv4: $ip4"
    break
  fi
  sleep 1
  if [ "$i" = "60" ]; then
    log "tailscale IPv4 did not become available"
    exit 1
  fi
done

relay_host=${DNS_RELAY_LISTEN%:*}
relay_port=${DNS_RELAY_LISTEN##*:}
log "starting integrated DNS relay on ${DNS_RELAY_LISTEN} to ${DNS_RELAY_TARGET}"
socat -T "$DNS_RELAY_IDLE_TIMEOUT" "UDP4-LISTEN:${relay_port},bind=${relay_host},reuseaddr,fork" "UDP4:${DNS_RELAY_TARGET}" &
DNS_RELAY_UDP_PID="$!"
socat "TCP4-LISTEN:${relay_port},bind=${relay_host},reuseaddr,fork" "TCP4:${DNS_RELAY_TARGET}" &
DNS_RELAY_TCP_PID="$!"

[ -f "$ADGUARD_CONF" ] || { log "missing AdGuardHome config: $ADGUARD_CONF"; exit 1; }

log "starting AdGuardHome"
"$ADGUARD_BIN" --no-check-update -c "$ADGUARD_CONF" -w "$ADGUARD_WORK" &
ADGUARD_PID="$!"

while :; do
  if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    log "tailscaled exited"
    wait "$TAILSCALED_PID" || true
    shutdown
    exit 1
  fi
  if ! kill -0 "$ADGUARD_PID" 2>/dev/null; then
    log "AdGuardHome exited"
    wait "$ADGUARD_PID" || true
    shutdown
    exit 1
  fi
  if ! kill -0 "$DNS_RELAY_UDP_PID" 2>/dev/null; then
    log "DNS UDP relay exited"
    wait "$DNS_RELAY_UDP_PID" || true
    shutdown
    exit 1
  fi
  if ! kill -0 "$DNS_RELAY_TCP_PID" 2>/dev/null; then
    log "DNS TCP relay exited"
    wait "$DNS_RELAY_TCP_PID" || true
    shutdown
    exit 1
  fi
  sleep 5
done
