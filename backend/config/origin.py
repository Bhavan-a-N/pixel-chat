"""WebSocket origin validation for production.

Rationale (verified empirically, see docs/adr/0028):

- Browsers always send an ``Origin`` header on a WebSocket handshake, so a
  present Origin must match ``ALLOWED_HOSTS``. This blocks cross-site
  WebSocket hijacking from any other origin.
- The Flutter client (dart:io) sends **no** ``Origin`` header at all. A
  strict ``AllowedHostsOriginValidator`` would deny every connection from our
  own app, so an absent Origin is treated as a non-browser client and allowed
  through. Access is still gated by JWT authentication at the handshake.
"""

from __future__ import annotations

from channels.security.websocket import OriginValidator
from django.conf import settings


class AppOriginValidator(OriginValidator):
    """OriginValidator that allows connections without an Origin header."""

    def valid_origin(self, parsed_origin) -> bool:
        if parsed_origin is None:
            return True
        return self.validate_origin(parsed_origin)


def app_origin_validator(application) -> AppOriginValidator:
    """Wrap an ASGI app with origin validation built from ALLOWED_HOSTS."""
    allowed_hosts = settings.ALLOWED_HOSTS
    if settings.DEBUG and not allowed_hosts:
        allowed_hosts = ["localhost", "127.0.0.1", "[::1]"]
    return AppOriginValidator(application, allowed_hosts)
