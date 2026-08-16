ARG ADGUARDHOME_IMAGE=docker.io/adguard/adguardhome:v0.107.78
ARG TAILSCALE_IMAGE=docker.io/tailscale/tailscale:v1.102.2

FROM ${ADGUARDHOME_IMAGE} AS adguardhome

FROM ${TAILSCALE_IMAGE} AS runtime

ARG TAILSCALE_IMAGE
ARG ADGUARDHOME_IMAGE
ARG PIPELINE_REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/hotwa/tailnet-dns-gw-image" \
      org.opencontainers.image.revision="$PIPELINE_REVISION" \
      io.jmsu.tailnet-dns-gw.tailscale-image="$TAILSCALE_IMAGE" \
      io.jmsu.tailnet-dns-gw.adguardhome-image="$ADGUARDHOME_IMAGE"

COPY --from=adguardhome /opt/adguardhome/AdGuardHome /opt/adguardhome/AdGuardHome
COPY entrypoint.sh /usr/local/bin/tailnet-dns-gw-entrypoint
COPY healthcheck.sh /usr/local/bin/tailnet-dns-gw-healthcheck
RUN apk add --no-cache bind-tools socat \
    && chmod +x /opt/adguardhome/AdGuardHome \
      /usr/local/bin/tailnet-dns-gw-entrypoint \
      /usr/local/bin/tailnet-dns-gw-healthcheck

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=30s \
  CMD ["/usr/local/bin/tailnet-dns-gw-healthcheck"]

ENTRYPOINT ["/usr/local/bin/tailnet-dns-gw-entrypoint"]

FROM runtime AS test
RUN /bin/sh -n /usr/local/bin/tailnet-dns-gw-entrypoint \
    && /bin/sh -n /usr/local/bin/tailnet-dns-gw-healthcheck \
    && tailscale version \
    && /opt/adguardhome/AdGuardHome --version \
    && command -v dig >/dev/null \
    && command -v socat >/dev/null
