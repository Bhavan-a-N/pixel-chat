# ADR 0028: WebSocket origin validation tolerates a missing Origin header

## Status

Accepted

## Context

ADR/Phase 2 required "proper WebSocket origin/host validation so only my app can connect". The obvious implementation — channels' `AllowedHostsOriginValidator` — was wired in, but it **denies any handshake without an `Origin` header** (`OriginValidator.valid_origin`: "None is not allowed unless all hosts are allowed").

The Flutter client uses `dart:io` WebSockets. Verified empirically against a raw header-dumping server (Dart 3.10):

```
GET /ws/chat/ HTTP/1.1
user-agent: Dart/3.10 (dart:io)
connection: Upgrade
sec-websocket-version: 13
host: 127.0.0.1:8765
sec-websocket-key: ...
upgrade: websocket
```

**No `origin` header.** With the strict validator, every production connection from the app would be rejected (immediate close), i.e. the app would not work at all.

## Decision

Custom `AppOriginValidator` in `backend/config/origin.py`, applied in `config/asgi.py` when `DEBUG=False`:

- **Origin present** → must match `ALLOWED_HOSTS`, otherwise the connection is denied. Browsers are required by RFC 6455 to send `Origin` on WebSocket handshakes, so this blocks cross-site WebSocket hijacking from any other site.
- **Origin absent** → allowed, treated as a non-browser client. Access is still gated by JWT validation in the WebSocket handshake (`4401` close code), which is the real authentication boundary.

Honest limitation: origin headers are trivially forgeable by any non-browser client, so this is a browser-side control, not authentication. A native-app attestation scheme would be needed for more, and is out of scope for ~3 invited users.

## Alternatives considered

- **`AllowedHostsOriginValidator` as-is:** rejected — breaks the app (no Origin header).
- **Send `Origin: https://<service>.onrender.com` from the Dart client:** works, but adds build-time coupling between the app binary and the host URL (a renamed service silently breaks all existing installs), and buys no real security since a native client can forge the header anyway.
- **Wildcard `ALLOWED_HOSTS = ["*"]`:** rejected — disables the browser-side control entirely.

## Consequences

- Android app connects with no Origin header; browsers from foreign origins are denied.
- Tests: `apps/chat/tests/test_websocket_origin.py` pin all four cases.
- If a web client is ever added, it must be served from a host listed in `ALLOWED_HOSTS`.
