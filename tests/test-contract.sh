#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

bash -n tests/test-contract.sh
sh -n entrypoint.sh
sh -n healthcheck.sh
bash -n scripts/deploy-digest.sh
bash -n scripts/check-stable-and-deploy.sh

grep -Fq 'TAILSCALE_MIN_VERSION=1.102.2' pipeline.env
grep -Fq 'ADGUARDHOME_MIN_VERSION=0.107.78' pipeline.env
grep -Fq 'TAILSCALE_REPOSITORY=tailscale/tailscale' pipeline.env
grep -Fq 'ADGUARDHOME_REPOSITORY=AdguardTeam/AdGuardHome' pipeline.env
grep -Fq 'FROM ${ADGUARDHOME_IMAGE} AS adguardhome' Dockerfile
grep -Fq 'FROM ${TAILSCALE_IMAGE} AS runtime' Dockerfile
grep -Fq 'COPY --from=adguardhome /opt/adguardhome/AdGuardHome' Dockerfile
grep -Fq 'ENTRYPOINT ["/usr/local/bin/tailnet-dns-gw-entrypoint"]' Dockerfile
grep -Fq 'environment: production-promotion' .github/workflows/promote-stable.yml
grep -Fq 'TAILNET_DNS_DEPLOY_CONFIRMED=1' scripts/check-stable-and-deploy.sh
grep -Fq 'last-successful-digest' scripts/check-stable-and-deploy.sh
grep -Fq 'IOSchedulingPriority=7' systemd/tailnet-dns-gw-registry-update.service

if grep -RInE '(TS_AUTHKEY|TOKEN|PASSWORD|SECRET)=.+' --exclude=test-contract.sh .; then
  echo 'possible plaintext secret assignment found' >&2
  exit 1
fi

echo 'contract tests passed'
