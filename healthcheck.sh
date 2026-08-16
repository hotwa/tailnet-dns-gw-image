#!/bin/sh
set -eu

TS_SOCKET="${TS_SOCKET:-/run/tailscale/tailscaled.sock}"
tailscale --socket="$TS_SOCKET" ip -4 >/dev/null
nc -z 127.0.0.1 53
nc -z 127.0.0.1 3000
nc -z 127.0.0.1 5354
dig +time=3 +tries=1 +short @127.0.0.1 -p 5354 one.one.one.one A |
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
