# Security policy

Do not commit Tailscale auth keys or state, AdGuard Home configuration/work
data, certificates, credentials, production `.env` files, or runtime logs.
Production deployments must use an immutable GHCR digest, preserve the
Tailscale state directory, back up service configuration, and retain the
previous local image for rollback.
