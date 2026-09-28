"""WebSocket origin validation policy (see config/origin.py, ADR 0028).

The Flutter client (dart:io) sends no Origin header, which the strict
channels AllowedHostsOriginValidator would reject. These tests pin the
intended behaviour: absent Origin allowed (non-browser client), present
Origin must match ALLOWED_HOSTS.
"""

import os

import pytest
from channels.testing import WebsocketCommunicator

os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"

from config.origin import app_origin_validator  # noqa: E402

ALLOWED_HOST = "pixelchat.onrender.com"


async def _accepting_app(scope, receive, send):
    await send({"type": "websocket.accept"})


@pytest.fixture
def prod_hosts(settings):
    settings.ALLOWED_HOSTS = [ALLOWED_HOST]
    settings.DEBUG = False
    return settings


async def _connect(headers):
    validator = app_origin_validator(_accepting_app)
    communicator = WebsocketCommunicator(validator, "/ws/chat/", headers=headers)
    connected, _ = await communicator.connect()
    if connected:
        await communicator.disconnect()
    return connected


async def test_no_origin_header_is_allowed(prod_hosts):
    # dart:io sends no Origin header at all (verified against a raw server).
    assert await _connect([]) is True


async def test_matching_origin_is_allowed(prod_hosts):
    headers = [(b"origin", f"https://{ALLOWED_HOST}".encode())]
    assert await _connect(headers) is True


async def test_foreign_origin_is_denied(prod_hosts):
    headers = [(b"origin", b"https://evil.example.com")]
    assert await _connect(headers) is False


async def test_same_host_pattern_matches_any_scheme(prod_hosts):
    # A bare host pattern in ALLOWED_HOSTS matches on hostname only, so an
    # http origin for the same host passes channels' OriginValidator. TLS
    # termination at Render makes the public endpoint https-only anyway.
    headers = [(b"origin", f"http://{ALLOWED_HOST}".encode())]
    assert await _connect(headers) is True
