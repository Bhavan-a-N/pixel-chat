import os
import pytest
from channels.layers import channel_layers

os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"


@pytest.fixture(autouse=True)
def reset_channel_layers():
    yield
    channel_layers.backends.clear()
