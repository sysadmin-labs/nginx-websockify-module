About
=====

[![Build & Test][build-test-badge]][build-test-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![HTTP/2][http2-badge]][http2-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

nginx-websockify-module - bridges a WebSocket to a plain TCP service, so a
browser can reach something that speaks neither HTTP nor WebSocket, such as
a VNC server.

[build-test-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/build-test.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/freebsd.yml
[http2-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/http2.yml/badge.svg
[http2-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/http2.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-websockify-module/actions/workflows/lint.yml

Status
======

In use.  The module builds against nginx 1.28.3, 1.30.5 and 1.31.6, both
statically and as a loadable object, and the suite runs on Linux and on
FreeBSD.

Two things were wrong and are fixed here, both measured before and after:

**An unreachable service was answered with a handshake.** The module told
nginx that a byte had arrived from a service it had not reached, so nginx
answered `101 Switching Protocols` for a tunnel that did not exist and the
client found out only when nothing ever came through.  A silent service and
an unreachable one look the same through `recv()`; the socket knows the
difference, and the module now asks it.  The answer is `502` as it should
be.  `t/handshake.t` had a case for exactly this since 2015 and it had never
passed.

**A handshake arriving over HTTP/2 made nginx fail instead of being
refused.** nginx logged `epoll_ctl(1, 3) failed (17: File exists) while
proxying upgraded connection` and the client got no answer at all.  HTTP/2
and HTTP/3 have no `Upgrade` mechanism -- carrying WebSocket over them needs
the extended CONNECT of RFC 8441, which nginx does not offer for upgraded
connections -- so such a request is now refused with `400` and a line in the
error log saying why.

That second one is the subject of upstream issue #24, whose diagnosis
("can not work with http2 ssl enabled") is wrong: with `http2 on` on the
listener a handshake over HTTP/1.1 answers `101` exactly as it should.
`ci/http2.sh` measures all three cases so that neither half can regress.

Configuration directives
========================

websockify_pass
---------------

* **syntax**: `websockify_pass <address>`
* **context**: location

The TCP service to bridge to.  Takes an `address:port`, and variables are
allowed, so `websockify_pass 127.0.0.1:$arg_port` works.

websockify_buffer_size
----------------------

* **syntax**: `websockify_buffer_size <size>`
* **default**: `4k|8k`
* **context**: http, server, location

Size of the two buffers used for encoding and decoding frames.

websockify_connect_timeout
--------------------------

* **syntax**: `websockify_connect_timeout <time>`
* **default**: `60s`
* **context**: http, server, location

websockify_send_timeout
-----------------------

* **syntax**: `websockify_send_timeout <time>`
* **default**: `60s`
* **context**: http, server, location

websockify_read_timeout
-----------------------

* **syntax**: `websockify_read_timeout <time>`
* **default**: `60s`
* **context**: http, server, location

Requirements
============

A WebSocket handshake is an HTTP/1.1 `Upgrade`, so the client has to arrive
over HTTP/1.1.  A listener may well carry `http2 on` at the same time; that
changes nothing for a WebSocket client, because HTTP/2 has no `Upgrade` and
clients therefore use HTTP/1.1 for it anyway.

The handshake needs SHA-1, which the module takes from nginx; a build with
`--with-http_ssl_module` provides it.

Sample configuration
====================

```nginx
server {
    listen 127.0.0.1:8080;

    location /websockify {
        websockify_pass 127.0.0.1:5901;

        websockify_read_timeout 1h;
        websockify_send_timeout 1h;
    }
}
```

The browser side connects to `ws://127.0.0.1:8080/websockify` and asks for
the `base64` or `binary` subprotocol; noVNC does both.

Test Suite
==========

The suite is written against
[Test::Nginx](https://metacpan.org/pod/Test::Nginx) and needs
`Protocol::WebSocket` and `Scope::OnExit` as well:

```
ci/build.sh 1.31.6 /tmp/nginx-test
TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
```

`ci/http2.sh` covers the HTTP/2 refusal, which Test::Nginx cannot send, and
`ci/reload.sh` reloads nginx eight times and asks for a real handshake after
every one of them.

License
=======

MIT, see [LICENSE](LICENSE).
