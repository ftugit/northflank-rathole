#!/bin/sh
set -eu

: "${RATHOLE_TOKEN:?RATHOLE_TOKEN is required}"

case "$RATHOLE_TOKEN" in
  *[!A-Za-z0-9]*|'')
    echo "RATHOLE_TOKEN must contain only letters and digits" >&2
    exit 1
    ;;
esac

cat > /tmp/server.toml <<EOF
[server]
bind_addr = "127.0.0.1:2333"
default_token = "$RATHOLE_TOKEN"
heartbeat_interval = 30

[server.transport]
type = "websocket"

[server.transport.websocket]
tls = false

[server.services.web]
type = "tcp"
token = "$RATHOLE_TOKEN"
bind_addr = "127.0.0.1:18080"
nodelay = true
EOF

if ! grep -q '^\[server\]$' /tmp/server.toml; then
    echo "Generated rathole config does not contain [server]" >&2
    exit 1
fi

/usr/local/bin/rathole --server /tmp/server.toml &
RATHOLE_PID=$!

sleep 1

if ! kill -0 "$RATHOLE_PID" 2>/dev/null; then
    echo "rathole exited during startup" >&2
    wait "$RATHOLE_PID" || true
    exit 1
fi

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