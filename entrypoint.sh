#!/bin/sh
set -eu

: "${RATHOLE_TOKEN:?RATHOLE_TOKEN is required}"

case "$RATHOLE_TOKEN" in
  *[!A-Za-z0-9._-]*|'')
    echo "RATHOLE_TOKEN must contain only letters, digits, dot, underscore or hyphen" >&2
    exit 1
    ;;
esac

sed "s/__RATHOLE_TOKEN__/$RATHOLE_TOKEN/g" \
  /etc/rathole/server.toml.tmpl \
  > /tmp/server.toml

/usr/local/bin/rathole --server /tmp/server.toml &
RATHOLE_PID=$!

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

cleanup() {
    kill "$RATHOLE_PID" "$CADDY_PID" 2>/dev/null || true
    wait || true
}

trap cleanup INT TERM

while kill -0 "$RATHOLE_PID" 2>/dev/null &&
      kill -0 "$CADDY_PID" 2>/dev/null; do
    sleep 2
done

exit 1