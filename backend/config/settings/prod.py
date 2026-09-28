from datetime import timedelta

import dj_database_url

from .base import *  # noqa: F403
from .base import SIMPLE_JWT as _BASE_SIMPLE_JWT
from .base import get_env_var
import os

from config.health import cache_redis_location

DEBUG = False

_allowed = os.getenv("ALLOWED_HOSTS", "")
ALLOWED_HOSTS = [h.strip() for h in _allowed.split(",") if h.strip()]
if not ALLOWED_HOSTS:
    print("Error: ALLOWED_HOSTS must list at least one host.")
    import sys

    sys.exit(1)

REDIS_URL = get_env_var("REDIS_URL")

DATABASES = {
    "default": dj_database_url.config(
        default=get_env_var("DATABASE_URL"),
        conn_max_age=int(os.getenv("DB_CONN_MAX_AGE", "60")),
        conn_health_checks=True,
        ssl_require=True,
    )
}

CHANNEL_LAYERS = {
    "default": {
        "BACKEND": "channels_redis.core.RedisChannelLayer",
        "CONFIG": {
            "hosts": [REDIS_URL],
        },
    },
}

CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": cache_redis_location(REDIS_URL, db_index=1),
        "OPTIONS": {
            "socket_connect_timeout": 2,
            "socket_timeout": 2,
        },
    },
}

_access_minutes = int(os.getenv("JWT_ACCESS_TOKEN_LIFETIME_MINUTES", "15"))
_refresh_days = int(os.getenv("JWT_REFRESH_TOKEN_LIFETIME_DAYS", "30"))

SIMPLE_JWT = {
    **_BASE_SIMPLE_JWT,
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=_access_minutes),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=_refresh_days),
}

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
SECURE_SSL_REDIRECT = os.getenv("SECURE_SSL_REDIRECT", "true").lower() in (
    "1",
    "true",
    "yes",
)
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SECURE_HSTS_SECONDS = int(os.getenv("SECURE_HSTS_SECONDS", "31536000"))
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = os.getenv("SECURE_HSTS_PRELOAD", "false").lower() in (
    "1",
    "true",
    "yes",
)
USE_X_FORWARDED_HOST = True

CSRF_TRUSTED_ORIGINS = [
    o.strip() for o in os.getenv("CSRF_TRUSTED_ORIGINS", "").split(",") if o.strip()
]
