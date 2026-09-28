import os

from django.core.asgi import get_asgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings.dev")

# Initialize Django ASGI application early to ensure the AppRegistry is populated
django_asgi_app = get_asgi_application()

from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402
from django.conf import settings  # noqa: E402

from apps.chat.middleware import JwtAuthMiddlewareStack  # noqa: E402
import apps.chat.routing  # noqa: E402
from config.origin import app_origin_validator  # noqa: E402

_websocket = JwtAuthMiddlewareStack(URLRouter(apps.chat.routing.websocket_urlpatterns))
if not settings.DEBUG:
    # Reject browser connections from foreign origins; tolerate the absent
    # Origin header that the Dart client sends (see config/origin.py).
    _websocket = app_origin_validator(_websocket)

application = ProtocolTypeRouter(
    {
        "http": django_asgi_app,
        "websocket": _websocket,
    }
)
