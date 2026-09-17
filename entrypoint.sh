#!/bin/sh
set -eu

: "${RATHOLE_TOKEN:?RATHOLE_TOKEN is required}"

case "$RATHOLE_TOKEN" in
  *[!A-Za-z0-9]*|'')
    echo "RATHOLE_TOKEN must contain only letters and digits" >&2
    exit 1
    ;;
esac

: "${RATHOLE_PUBLIC_HOST:?RATHOLE_PUBLIC_HOST is required}"

if [ -z "${RATHOLE_PUBLIC_HOST}" ]; then
    echo "RATHOLE_PUBLIC_HOST is required" >&2
    exit 1
fi

# Валидация хоста чтобы не сломать Caddyfile (только безопасные символы)
case "$RATHOLE_PUBLIC_HOST" in
  *[!A-Za-z0-9.-]*)
    echo "RATHOLE_PUBLIC_HOST contains invalid characters (allowed: letters, digits, dot, hyphen)" >&2
    exit 1
    ;;
esac

# --- Секрет Cloudflare (заголовок X-Origin-Auth) ------------------------------
# Теперь ОПЦИОНАЛЕН: если не задан — защита выключена (открытый доступ).
# Если задан — валидируем и включаем проверку в Caddyfile.
CF_ENABLED=0
if [ -n "${CF_ORIGIN_SECRET:-}" ]; then
    if [ "${#CF_ORIGIN_SECRET}" -lt 32 ]; then
        echo "CF_ORIGIN_SECRET must be at least 32 characters" >&2
        exit 1
    fi
    # Только буквы и цифры: защищает Caddyfile от пробелов, переводов строк, $ и {}
    # Сгенерировать: openssl rand -hex 32
    case "$CF_ORIGIN_SECRET" in
      *[!A-Za-z0-9]*|'')
        echo "CF_ORIGIN_SECRET must contain only letters and digits (openssl rand -hex 32)" >&2
        exit 1
        ;;
    esac
    CF_ENABLED=1
else
    echo "CF_ORIGIN_SECRET not set — Cloudflare origin protection DISABLED (open access)" >&2
fi

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

mkdir -p /etc/caddy

# --- Генерация Caddyfile ---------------------------------------------------
# RATHOLE_PUBLIC_HOST теперь без дефолта — обязателен (проверено выше).
# CF_ORIGIN_SECRET опционален — генерируем два разных конфига.

{
cat <<EOF
{
	auto_https off
}

:8080 {
	bind 0.0.0.0

	log {
		output stdout
		format filter {
			wrap json
			request>headers>X-Origin-Auth delete
			request>headers>Cookie delete
		}
	}

	handle /healthz {
		respond "ok" 200
	}

	@rathole_control {
		host $RATHOLE_PUBLIC_HOST
		header Upgrade websocket
	}
	handle @rathole_control {
		reverse_proxy 127.0.0.1:2333
	}

EOF

if [ "$CF_ENABLED" -eq 1 ]; then
cat <<EOF
	@cloudflare_origin header X-Origin-Auth $CF_ORIGIN_SECRET
	handle @cloudflare_origin {
		reverse_proxy 127.0.0.1:18080 {
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-Port 443
			header_up X-Real-IP {http.request.header.CF-Connecting-IP}
			header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
			header_up -X-Origin-Auth
		}
	}
	handle {
		respond "origin access denied" 403
	}
EOF
else
cat <<EOF
	# Cloudflare protection disabled — берём IP от Northflank Envoy,
	# т.к. CF-Connecting-IP без Cloudflare не существует
	handle {
		reverse_proxy 127.0.0.1:18080 {
			header_up Host {http.request.host}
			header_up X-Forwarded-Proto https
			header_up X-Forwarded-Port 443
			header_up X-Real-IP {http.request.header.X-Forwarded-For}
			header_up X-Forwarded-For {http.request.header.X-Forwarded-For}
			header_up X-Envoy-External-Address {http.request.header.X-Envoy-External-Address}
		}
	}
EOF
fi

cat <<EOF
}
EOF
} > /etc/caddy/Caddyfile

echo "Generated Caddyfile (CF protection: $([ "$CF_ENABLED" -eq 1 ] && echo "enabled" || echo "disabled")):" >&2
cat /etc/caddy/Caddyfile >&2

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
