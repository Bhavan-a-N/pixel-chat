"""Shared health probe helpers for liveness and readiness endpoints."""

from __future__ import annotations

import logging
from urllib.parse import urlparse, urlunparse

import redis
from django.conf import settings
from django.db import connection

logger = logging.getLogger(__name__)


def check_database() -> bool:
    """Probe Postgres, dropping and retrying once if the pooled connection is stale.

    Neon suspends idle compute and PgBouncer can drop idle connections, so a
    single probe failure may just mean "connection is dead", not "database is
    down". Close the bad connection (which forces a reconnect on the retry)
    before concluding the DB is unavailable.
    """
    for attempt in (1, 2):
        try:
            connection.ensure_connection()
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                row = cursor.fetchone()
            return bool(row and row[0] == 1)
        except Exception:
            logger.exception("health_db_check_failed attempt=%s", attempt)
            if connection.in_atomic_block:
                # Never close inside a transaction block (tests, atomic views).
                return False
            try:
                connection.close()
            except Exception:
                logger.exception("health_db_close_failed")
    return False


def _redis_url_for_ping() -> str:
    layer_hosts = settings.CHANNEL_LAYERS["default"]["CONFIG"]["hosts"]
    if layer_hosts:
        return layer_hosts[0]
    return ""


def check_redis() -> bool:
    redis_url = _redis_url_for_ping()
    if not redis_url:
        return False
    try:
        client = redis.from_url(redis_url, socket_connect_timeout=2, socket_timeout=2)
        return client.ping()
    except Exception:
        logger.exception("health_redis_check_failed")
        return False


def cache_redis_location(channel_redis_url: str, db_index: int = 1) -> str:
    """Use a separate Redis logical DB for Django cache vs Channels."""
    parsed = urlparse(channel_redis_url)
    return urlunparse(parsed._replace(path=f"/{db_index}"))
