#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

bash -n tests/test-contract.sh
sh -n entrypoint.sh
sh -n healthcheck.sh

grep -Fq 'TAILSCALE_MIN_VERSION=1.102.2' pipeline.env
grep -Fq 'ADGUARDHOME_MIN_VERSION=0.107.78' pipeline.env
grep -Fq 'TAILSCALE_REPOSITORY=tailscale/tailscale' pipeline.env
grep -Fq 'ADGUARDHOME_REPOSITORY=AdguardTeam/AdGuardHome' pipeline.env
grep -Fq 'FROM ${ADGUARDHOME_IMAGE} AS adguardhome' Dockerfile
grep -Fq 'FROM ${TAILSCALE_IMAGE} AS runtime' Dockerfile
grep -Fq 'COPY --from=adguardhome /opt/adguardhome/AdGuardHome' Dockerfile
grep -Fq 'ENTRYPOINT ["/usr/local/bin/tailnet-dns-gw-entrypoint"]' Dockerfile
grep -Fq 'environment: production-promotion' .github/workflows/promote-stable.yml

if grep -RInE '(TS_AUTHKEY|TOKEN|PASSWORD|SECRET)=.+' --exclude=test-contract.sh .; then
  echo 'possible plaintext secret assignment found' >&2
  exit 1
fi

echo 'contract tests passed'
