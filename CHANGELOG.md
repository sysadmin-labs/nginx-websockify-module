# Changelog

Newest first.  Dates are release dates.

## Unreleased

### Fixed

- **The handshake is no longer answered before the connection exists.**  The
  first attempt at this asked the socket harder, which cannot work: measured
  on FreeBSD 15.1, the RST of a refused connect has not arrived while
  `reinit_request` runs, so there is nothing to see -- not through
  `SO_ERROR`, not through kqueue.  The module answered `101`, nginx then
  failed in `setsockopt(TCP_NODELAY)` and finalised with 500, and the client
  got nothing at all.
- What works is to stop pre-empting nginx.  `reinit_request` now only marks
  `c->read->ready` instead of calling the read event handler itself, so
  everything happens in nginx's own order: the connect finishes, nginx makes
  its own `test_connect` -- which does see the failure, on both platforms,
  and answers **502** -- the request is sent, and only then does nginx call
  `process_header`, because the read is marked ready.  Something still has
  to stand in for a read, because the upstream speaks RFB and not HTTP and
  may never send a byte of its own; this does, without deciding the
  connect's fate.
- Dropping the eager call alone is not enough either, and that was measured
  too: without any stand-in, 12 of 13 handshake tests fail because nothing
  ever triggers `process_header`.
- **A handshake this module cannot serve is refused with 400 before any
  connection is made.**  A missing `Sec-WebSocket-Key`, or a
  `Sec-WebSocket-Protocol` that asks for neither base64 nor binary, is a
  property of the request, so it is settled in the content handler.
  `process_header` used to answer that from after the connection, and once
  nginx calls that function out of its own `send_request` path the 400 never
  reached the client -- which is what `t/handshake.t` TEST 3 and TEST 5
  caught.
- Verified on both platforms with the same source: FreeBSD 15.1 and Linux,
  36 tests each, no `alert` in the error log, and on Linux the HTTP/2 and
  reload gates at exit 0.

- **An unreachable service was answered with a handshake.**
  `ngx_http_websockify_empty_recv` told nginx that a byte had arrived from a
  service it had not reached, so nginx answered `101 Switching Protocols`
  for a tunnel that did not exist.  A silent service and an unreachable one
  look the same through `recv()` -- the socket knows the difference, and
  `reinit_request` now asks it with the same test nginx makes in its own
  `ngx_http_upstream_test_connect()`, which is static and out of reach.
  Measured on nginx 1.30.5: `HTTP 101` before, `HTTP 502` after.
  `t/handshake.t` TEST 2 asked for exactly that and had never passed since
  it was written in 2015.
- Two attempts before that one are worth recording, because both looked
  right and were not.  Reporting the error from inside the read callback
  gave the correct 502 but made nginx log `http request count is zero while
  closing request` -- the request was finalised while nginx was still
  working on it.  Returning `NGX_ERROR` out of `reinit_request` made it
  `500`, because nginx reads that as an internal error rather than an
  upstream one.  What works is to hand the request back untouched: nginx
  makes the same test when it sends the request and produces 502 on its own
  way.  The module does not have to report the failure, it only has to stop
  inventing a byte.
- **A handshake arriving over HTTP/2 made nginx fail instead of being
  refused.** nginx logged `epoll_ctl(1, 3) failed (17: File exists) while
  proxying upgraded connection` and the client got no answer at all.  HTTP/2
  and HTTP/3 have no `Upgrade` mechanism, so such a request is now refused
  with `400` and an `[info]` line saying why.
- That is upstream issue #24, and the diagnosis in it -- "can not work with
  http2 ssl enabled" -- is wrong.  Measured with `listen ... ssl; http2 on;`:
  a handshake over HTTP/1.1 on that same listener answers `101` exactly as
  it should.  `http2` being enabled is not the problem; a request that really
  arrives over HTTP/2 is.  This matters for the package rather than only on
  paper, because `www/nginx` ships `HTTPV2` as a default option -- and the
  answer is that the option is harmless.
- `t/transport.t` no longer compiled at all with today's Perl.
  `Test::Nginx::Util::kill_process` is prototyped `($$$)` now and wants a
  name as its third argument; the two further errors Perl reported, about
  `add_block_preprocessor` and `on_scope_exit` wanting a block, were fallout
  from the aborted compilation and went away with the one fix.

### Added

- A third block in `valgrind.suppress`, for the pool of nginx's master
  cycle: `posix_memalign` <- `ngx_memalign` <- `ngx_create_pool` <- `main`,
  which is nginx before a single module is loaded.  The sibling modules did
  not need it; this suite reaches it.  The header of the file now says three
  rather than two, because a file whose purpose is to record a measurement
  must not carry a wrong one.
- The valgrind workflow runs `t/handshake.t` rather than the whole suite,
  and that is measured, not a shortcut: the whole suite under valgrind ran
  for over 24 minutes without finishing, all of it in `t/transport.t`, which
  drives real sockets with sleeps.  Under valgrind that test is not telling
  either, because two writes end up in one websocket frame and it expects
  them apart.  `t/handshake.t` takes 125 seconds including the waits and
  covers the path where this module allocates.
- `TEST_NGINX_TIMEOUT=30` for that job.  Without it TEST 2 fails on the
  clock rather than on the module: it waits for a refused connect, and under
  valgrind nginx answers later than the default three seconds.

- `ci/http2.sh` and a workflow of its own.  It measures all three cases, not
  only the broken one: a plain HTTP/1.1 handshake has to answer `101`, one on
  a listener with `http2 on` has to answer `101` as well, and only a request
  over HTTP/2 has to be refused with `400`.  A gate that held just the last
  of those would not notice if the refusal took the working handshake with
  it.  Two further oracles: the refusal has to say why in the error log, and
  an `[alert]`, `[crit]`, `[emerg]` or a worker killed by a signal fails the
  run -- the `epoll_ctl` alert was the whole reason for the check.
- Proven against a planted defect: with the refusal taken out of the module
  again, three oracles fire at once -- `HTTP 000, expected 400`, "nothing in
  the error log explains the refusal", and the `epoll_ctl(1, 3) failed (17:
  File exists)` alert -- while both HTTP/1.1 cases stay green.
- `ci/build.sh` builds with `--with-http_v2_module`, because `www/nginx`
  ships `HTTPV2` by default and a gate that measured a build without it
  would be measuring something nobody installs.
- The repository scaffolding the sibling modules carry: a reload gate with a
  real handshake as its probe, download sources verified against pinned
  digests, a time bound on every CI job, the sanitizers, valgrind, CodeQL
  and the linters, and a FreeBSD job that runs the suite in a virtual
  machine.
- The setup action takes a `cpan` input now, because this suite needs
  `Protocol::WebSocket` as well as `Test::Nginx`.  It also installs
  `liblwp-protocol-https-perl` first: without it cpanm cannot reach
  cpanmetadb over HTTPS at all and every lookup fails with "Finding
  <module> on cpanmetadb failed", which is how this was found.
- `t/transport.t` no longer needs `Scope::OnExit`.  There is no
  `p5-Scope-OnExit` in the FreeBSD ports tree, so it would have had to come
  from CPAN inside the FreeBSD job; a seven line guard object whose
  destructor runs the callback does the same thing and runs everywhere.

### Removed

- `Dockerfile`, `.github/FUNDING.yml`, `nginx.conf` and
  `nginx.vh.default.conf`.  The two configurations said no more than the
  README does.
