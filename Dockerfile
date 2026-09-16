FROM rapiz1/rathole:v0.5.0 AS rathole
FROM caddy:2 AS caddy

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/caddy /etc/rathole /data/caddy /config/caddy

COPY --from=rathole /app/rathole /usr/local/bin/rathole
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh \
    && test -x /usr/local/bin/rathole

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]