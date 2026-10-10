#!/bin/sh
#
# A websocket handshake is an HTTP/1.1 Upgrade.  HTTP/2 and HTTP/3 have no
# Upgrade mechanism at all -- carrying websockets over them needs the
# extended CONNECT of RFC 8441, which nginx does not offer for upgraded
# connections.  So the only correct answer to such a request is a refusal.
#
# Upstream issue #24 reported this as "can not work with http2 ssl enabled",
# and the diagnosis in it is wrong, which is why this script measures all
# three cases rather than one.  With "http2 on" on the listener the
# handshake over HTTP/1.1 answers 101 exactly as it should -- http2 being
# enabled is not the problem.  A request that really arrives over HTTP/2 is,
# and before the refusal it was not even a clean failure: nginx logged
# "epoll_ctl(1, 3) failed (17: File exists) while proxying upgraded
# connection" and the client got no answer at all.
#
# This matters for the package and not only on paper: www/nginx ships
# HTTPV2 as a default option.
#
# usage: ci/http2.sh <nginx binary>

set -eu

NGINX=${1:?path to the nginx binary missing}
WORK=${CI_WORK:-$(cd "$(dirname "$0")/.." && pwd)/ci-work}/http2
PORT=${HTTP2_PORT:-18800}
SPORT=${HTTP2_TLS_PORT:-18843}
BPORT=${HTTP2_PEER_PORT:-18902}

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }
command -v openssl > /dev/null || { echo "openssl(1) is needed" >&2; exit 2; }
command -v python3 > /dev/null || { echo "python3 is needed for the peer" >&2; exit 2; }

curl -V | grep -q HTTP2 || { echo "this curl cannot speak HTTP/2" >&2; exit 2; }
"$NGINX" -V 2>&1 | grep -q http_v2_module || {
	echo "this nginx was built without http_v2" >&2
	exit 2
}

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs"

fail=0
note() {
	echo "  $1" >&2
	fail=1
}

# ------------------------------------------------------------------ the peer
#
# Something that answers like a VNC server: a banner, then silence.  The
# module exists to bridge a websocket to exactly that.

cat > "$WORK/peer.py" <<'PEER'
import socket
import sys
import threading

PORT = int(sys.argv[1])


def serve(c):
    try:
        c.sendall(b"RFB 003.008\n")
        while True:
            if not c.recv(4096):
                break
    except OSError:
        pass
    finally:
        try:
            c.close()
        except OSError:
            pass


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(16)
print("ready", flush=True)
while True:
    conn, _ = srv.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
PEER

python3 "$WORK/peer.py" "$BPORT" > "$WORK/peer.out" 2>&1 &
PEER_PID=$!

stop() {
	kill "$PEER_PID" 2> /dev/null
	[ -s "$WORK/logs/nginx.pid" ] && kill "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null
	return 0
}
trap stop EXIT

n=0
while [ $n -lt 50 ]; do
	grep -q ready "$WORK/peer.out" 2> /dev/null && break
	n=$((n + 1))
	sleep 0.1 2> /dev/null || sleep 1
done
grep -q ready "$WORK/peer.out" 2> /dev/null || {
	echo "the peer did not come up:" >&2
	cat "$WORK/peer.out" >&2
	exit 1
}

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
	-days 2 -nodes -subj /CN=localhost > /dev/null 2>&1

# ---------------------------------------------------------------- the server

ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

cat > "$WORK/conf/nginx.conf" <<EOF
$ngx_user
worker_processes 1;
error_log $WORK/logs/error.log info;
pid $WORK/logs/nginx.pid;
events { worker_connections 32; }
http {
    access_log off;

    server {
        listen 127.0.0.1:$PORT;

        location /ws {
            websockify_pass 127.0.0.1:$BPORT;
        }
    }

    server {
        listen 127.0.0.1:$SPORT ssl;
        http2 on;

        ssl_certificate     $WORK/cert.pem;
        ssl_certificate_key $WORK/key.pem;

        location /ws {
            websockify_pass 127.0.0.1:$BPORT;
        }
    }
}
EOF

echo "--- the configuration is read ---"
"$NGINX" -p "$WORK" -c conf/nginx.conf -t

"$NGINX" -p "$WORK" -c conf/nginx.conf
sleep 1

handshake() { # handshake <scheme> <port> [curl args...]
	scheme=$1
	port=$2
	shift 2
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -k "$@" \
		-H 'Connection: Upgrade' \
		-H 'Upgrade: websocket' \
		-H 'Sec-WebSocket-Key: n2wfgJF+qto2ahU4+aoNkQ==' \
		-H 'Sec-WebSocket-Protocol: base64' \
		-H 'Sec-WebSocket-Version: 13' \
		-H 'Origin: http://0' \
		"$scheme://127.0.0.1:$port/ws" 2> /dev/null || true)
	# curl prints the status before it can fail, so the two would end up
	# concatenated if this were "|| echo 000"
	[ -n "$code" ] || code=000
	echo "$code"
}

echo "--- a plain HTTP/1.1 handshake still works ---"
code=$(handshake http "$PORT")
if [ "$code" = 101 ]; then
	echo "  101"
else
	note "HTTP $code, expected 101 -- without this the rest means nothing"
fi

echo "--- and so does one on a listener with http2 on ---"
code=$(handshake https "$SPORT" --http1.1)
if [ "$code" = 101 ]; then
	echo "  101, so http2 on the listener is not the problem"
else
	note "HTTP $code, expected 101"
fi

echo "--- a request that really arrives over HTTP/2 is refused ---"
code=$(handshake https "$SPORT" --http2)
if [ "$code" = 400 ]; then
	echo "  400, and the reason is in the error log"
elif [ "$code" = 101 ]; then
	note "HTTP 101 over HTTP/2, where Upgrade does not exist"
else
	note "HTTP $code, expected 400"
fi

echo "--- and the refusal says why ---"
if grep -q "a websocket handshake needs HTTP/1.1" "$WORK/logs/error.log"; then
	echo "  yes"
else
	note "nothing in the error log explains the refusal"
fi

echo "--- nginx is still running ---"
if [ -s "$WORK/logs/nginx.pid" ] &&
	kill -0 "$(cat "$WORK/logs/nginx.pid")" 2> /dev/null; then
	echo "  yes"
else
	note "the master is gone"
fi

# The epoll_ctl alert is the whole point of this check, so it is not enough
# that nothing crashed.
if grep -qE '\[alert\]|\[crit\]|\[emerg\]|exited on signal' "$WORK/logs/error.log" 2> /dev/null; then
	echo "--- the error log complains ---" >&2
	grep -E '\[alert\]|\[crit\]|\[emerg\]|exited on signal' "$WORK/logs/error.log" | head -5 >&2
	fail=1
fi

[ "$fail" -eq 0 ]
