FROM rapiz1/rathole:v0.5.0 AS rathole

# Используем Debian-based Caddy, потому что официальный rathole binary
# собран под glibc.
FROM caddy:2

COPY --from=rathole /app/rathole /usr/local/bin/rathole

COPY server.toml.tmpl /etc/rathole/server.toml.tmpl
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]