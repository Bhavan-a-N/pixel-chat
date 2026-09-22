import asyncio
import os
import pytest
from channels.db import database_sync_to_async
from channels.layers import channel_layers
from django.db import close_old_connections

os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"


@pytest.fixture(autouse=True)
def reset_channel_layers(request):
    yield
    channel_layers.backends.clear()
    # Only drain the Channels worker-thread DB connections after async tests.
    # Sync tests never call database_sync_to_async, so there is nothing to
    # close — and calling asyncio.get_event_loop() without a running loop
    # raises DeprecationWarning in Python 3.12.
    if asyncio.iscoroutinefunction(request.node.function):
        loop = asyncio.get_event_loop()
        if not loop.is_closed():
            loop.run_until_complete(database_sync_to_async(close_old_connections)())


@pytest.fixture(autouse=True)
def configure_test_jwt_signing_key(settings):
    # Dedicated test key distinct from .env SECRET_KEY, >= 32 bytes (256 bits) for HMAC-SHA256
    test_key = "test-dedicated-jwt-signing-key-32bytes-long-min!"
    settings.SECRET_KEY = test_key
    settings.SIMPLE_JWT = {
        **settings.SIMPLE_JWT,
        "SIGNING_KEY": test_key,
    }
