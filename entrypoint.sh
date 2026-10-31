#!/bin/sh
set -eu
umask 077

: "${RATHOLE_TOKEN:?RATHOLE_TOKEN is required}"

case "$RATHOLE_TOKEN" in
  *[!A-Za-z0-9]*|'')
    echo "RATHOLE_TOKEN must contain only letters and digits" >&2
    exit 1
    ;;
esac

: "${RATHOLE_PUBLIC_HOST:?RATHOLE_PUBLIC_HOST is required}"

# Валидация хоста чтобы не сломать Caddyfile (только безопасные символы)
case "$RATHOLE_PUBLIC_HOST" in
  *[!A-Za-z0-9.-]*)
    echo "RATHOLE_PUBLIC_HOST contains invalid characters (allowed: letters, digits, dot, hyphen)" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------- tunables
# heartbeat_interval сервера. Инвариант: client.heartbeat_timeout >= 3 * heartbeat_interval.
# 10 c -> клиент с heartbeat_timeout=90 переживает «залипы» до 90 c, а мёртвый клиент виден за ~10-20 c.
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-10}"
case "$HEARTBEAT_INTERVAL" in ''|*[!0-9]*) echo "HEARTBEAT_INTERVAL must be an integer" >&2; exit 1;; esac

# --- Секрет для origin-защиты (заголовок X-Origin-Auth) ----------------------
CF_ENABLED=0
if [ -n "${CF_ORIGIN_SECRET:-}" ]; then
    if [ "${#CF_ORIGIN_SECRET}" -lt 32 ]; then
        echo "CF_ORIGIN_SECRET must be at least 32 characters" >&2
        exit 1
    fi
    case "$CF_ORIGIN_SECRET" in
      *[!A-Za-z0-9]*|'')
        echo "CF_ORIGIN_SECRET must contain only letters and digits (openssl rand -hex 32)" >&2
        exit 1
        ;;
    esac
    CF_ENABLED=1
else
    echo "CF_ORIGIN_SECRET not set — origin protection DISABLED (open access)" >&2
fi

# Optional egress tunnel. Disabled unless a sufficiently strong secret exists.
# Use the existing rathole hostname and a fixed, non-secret path; authentication
# is a header, not a URL (URLs are commonly logged by ingress/CDN).
EGRESS_ENABLED=0
if [ -n "${EGRESS_SECRET:-}" ]; then
    if [ "${#EGRESS_SECRET}" -lt 64 ]; then
        echo "EGRESS_SECRET must contain at least 64 alphanumeric characters" >&2
        exit 1
    fi
    case "$EGRESS_SECRET" in
      *[!A-Za-z0-9]*|'') echo "EGRESS_SECRET must be alphanumeric" >&2; exit 1;;
    esac
    EGRESS_PUBLIC_HOST="${EGRESS_PUBLIC_HOST:-$RATHOLE_PUBLIC_HOST}"
    case "$EGRESS_PUBLIC_HOST" in
      *[!A-Za-z0-9.-]*|'') echo "EGRESS_PUBLIC_HOST contains invalid characters" >&2; exit 1;;
    esac
    EGRESS_ENABLED=1
fi

# ---------------------------------------------------------------- rathole
# ВАЖНО: сервер слушает 0.0.0.0:2333 (снаружи доступен только через Caddy на :8080,
# но health-check Northflank и отладка из контейнера работают).
cat > /tmp/server.toml <<EOF
[server]
bind_addr = "0.0.0.0:2333"
default_token = "$RATHOLE_TOKEN"
heartbeat_interval = $HEARTBEAT_INTERVAL

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

# ---------------------------------------------------------------- Caddyfile
# Ключевые отличия от исходника:
#   * у @rathole_control добавлен match на rathole-подпуть — data-каналы больше
#     не попадают под «catch-all» handle с таймаутами обычного HTTP-прокси;
#   * idle-таймауты увеличены, чтобы длинные WS не срезались краем;
#   * flush_interval -1 и transport http1 — чтобы WS не буферизовался.
{
cat <<EOF
{
	auto_https off
	servers {
		timeouts {
			read_body 0
			idle 0
		}
	}
}

:8080 {
	bind 0.0.0.0

	log {
		output stdout
		format filter {
			wrap json
			request>headers>X-Origin-Auth delete
			request>headers>X-Egress-Auth delete
			request>headers>Cookie delete
		}
	}

	handle /healthz {
		respond "ok" 200
	}

EOF

if [ "$EGRESS_ENABLED" -eq 1 ]; then
cat <<EOF
	# Egress is matched before the broad rathole WebSocket handler.
	@egress_allowed {
		host $EGRESS_PUBLIC_HOST
		path /vyce-egress/*
		header Upgrade websocket
		header X-Egress-Auth $EGRESS_SECRET
	}
	handle @egress_allowed {
		reverse_proxy 127.0.0.1:18081 {
			header_up -X-Egress-Auth
			flush_interval -1
			transport http {
				versions 1.1
			}
		}
	}
	@egress_denied {
		host $EGRESS_PUBLIC_HOST
		path /vyce-egress/*
	}
	handle @egress_denied {
		respond "forbidden" 403
	}
EOF
fi

cat <<EOF
	# 1) control + data каналы rathole (WebSocket upgrade)
	@rathole_control {
		host $RATHOLE_PUBLIC_HOST
		header Upgrade websocket
	}
	handle @rathole_control {
		reverse_proxy 127.0.0.1:2333 {
			flush_interval -1
			transport http {
				versions 1.1
			}
		}
	}

EOF

if [ "$CF_ENABLED" -eq 1 ]; then
cat <<EOF
	@cloudflare_origin header X-Origin-Auth $CF_ORIGIN_SECRET
	handle @cloudflare_origin {
		reverse_proxy 127.0.0.1:18080 {
			flush_interval -1
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
	handle {
		reverse_proxy 127.0.0.1:18080 {
			flush_interval -1
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

# The generated Caddyfile contains secrets; never print it to logs.
echo "Generated Caddyfile (CF protection: $([ "$CF_ENABLED" -eq 1 ] && echo enabled || echo disabled); egress: $([ "$EGRESS_ENABLED" -eq 1 ] && echo enabled || echo disabled))" >&2

# ---------------------------------------------------------------- процессы
/usr/local/bin/rathole --server /tmp/server.toml &
RATHOLE_PID=$!

sleep 1

if ! kill -0 "$RATHOLE_PID" 2>/dev/null; then
    echo "rathole exited during startup" >&2
    wait "$RATHOLE_PID" || true
    exit 1
fi

WSTUNNEL_PID=""
if [ "$EGRESS_ENABLED" -eq 1 ]; then
    /usr/local/bin/wstunnel server --log-lvl WARN \
        --restrict-config /etc/wstunnel/restrictions.yaml \
        ws://127.0.0.1:18081 &
    WSTUNNEL_PID=$!
fi

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

cleanup() {
    kill "$RATHOLE_PID" "$CADDY_PID" ${WSTUNNEL_PID:+"$WSTUNNEL_PID"} 2>/dev/null || true
    wait || true
}
trap cleanup INT TERM

while kill -0 "$RATHOLE_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
    if [ -n "$WSTUNNEL_PID" ] && ! kill -0 "$WSTUNNEL_PID" 2>/dev/null; then
        echo "egress tunnel exited; shutting down" >&2
        cleanup
        exit 1
    fi
    sleep 2
done
cleanup

exit 1
