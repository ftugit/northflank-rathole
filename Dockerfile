FROM rapiz1/rathole:v0.5.0 AS rathole
FROM caddy:2 AS caddy
# The official container uses a newer glibc than bookworm; use the static
# release binary instead, pinned to the official published checksums.
FROM debian:bookworm-slim AS wstunnel-download
ARG TARGETARCH=amd64
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && case "$TARGETARCH" in \
         amd64) sum=512edf4e7bb64fc133522220123514868fae75b5bae4124b53e396787276aa23 ;; \
         arm64) sum=148895f957a68be39e2b65d28c5f2065b9c58c4a0cfd48c560b2b3267f398464 ;; \
         *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/erebe/wstunnel/releases/download/v11.1.0/wstunnel_11.1.0_linux_${TARGETARCH}.tar.gz" -o /tmp/wstunnel.tar.gz \
    && echo "$sum  /tmp/wstunnel.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/wstunnel.tar.gz -C /tmp wstunnel \
    && chmod 0755 /tmp/wstunnel

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/caddy /etc/rathole /data/caddy /config/caddy

COPY --from=rathole /app/rathole /usr/local/bin/rathole
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY --from=wstunnel-download /tmp/wstunnel /usr/local/bin/wstunnel

COPY wstunnel-restrictions.yaml /etc/wstunnel/restrictions.yaml
COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh \
    && test -x /usr/local/bin/rathole

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
