# Tailnet DNS Gateway image

This repository builds the combined Tailscale + AdGuard Home image used by the
ECS `tailscale-gw` service. It contains no authentication keys, Tailscale state,
AdGuard configuration, certificates, or production Compose environment.

## Image contents

- The official Tailscale stable container supplies `tailscaled`, `tailscale`,
  Alpine Linux, and the container runtime behavior.
- The official AdGuard Home stable container supplies only the
  `/opt/adguardhome/AdGuardHome` binary.
- `entrypoint.sh` starts the persisted Tailscale identity, the Tailnet-only
  AdGuard Home instance, and the bounded TCP/UDP DNS relay.
- `healthcheck.sh` verifies the Tailscale address, AdGuard listeners, relay
  listener, and a real DNS lookup.

## Release flow

The scheduled workflow runs daily at 20:47 UTC. It reads each project's latest
official non-prerelease GitHub release, rejects versions below the production
baseline in `pipeline.env`, and resolves the corresponding Docker tags to full
immutable manifest digests. A new candidate is built only when either digest or
this repository revision changes. The build uses the exact digests, tests both
binaries and both shell scripts, publishes an amd64 candidate to GHCR, generates
SBOM/provenance, and creates an attestation.

Candidates never update production. `Promote candidate to stable` requires the
`production-promotion` GitHub Environment approval. ECS should deploy only an
approved `stable` digest with service-specific health checks and rollback; it
must not build this image or blindly follow a moving tag.

The `scripts/` and `systemd/` directories provide that deployment layer. The
first digest deployment is an explicit write-gated operation. Later timer runs
only deploy a different operator-promoted `stable` digest, preserve the current
Tailnet IPv4, back up both AdGuard configurations and Tailscale state, validate
the complete DNS path, and restore the previous local image on failure.

No Docker Hub credential is required: the workflow reads public upstream images
and publishes to GHCR with its repository-scoped `GITHUB_TOKEN`.

## Local checks

```sh
tests/test-contract.sh
docker build --target test .
```
