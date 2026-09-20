from typing import Any, Dict, Optional
from channels.db import database_sync_to_async
from django.contrib.auth import get_user_model
from django.contrib.auth.models import AnonymousUser
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError
from rest_framework_simplejwt.tokens import AccessToken

User = get_user_model()


@database_sync_to_async
def get_user_from_token(token_str: str) -> Optional[Any]:
    try:
        token = AccessToken(token_str)
        user_id = token["user_id"]
        user = User.objects.filter(id=user_id, is_active=True).first()
        return user
    except (InvalidToken, TokenError, Exception):
        return None


class JwtAuthMiddleware:
    def __init__(self, inner):
        self.inner = inner

    async def __call__(self, scope: Dict[str, Any], receive, send):
        headers = dict(scope.get("headers", []))
        auth_header = headers.get(b"authorization", b"").decode("utf-8")

        user = None
        auth_error = None

        if auth_header:
            parts = auth_header.split()
            if len(parts) == 2 and parts[0].lower() == "bearer":
                raw_token = parts[1]
                user = await get_user_from_token(raw_token)
                if user is None:
                    auth_error = "invalid_or_expired_token"
            else:
                auth_error = "malformed_auth_header"
        else:
            auth_error = "missing_auth_header"

        if user is not None:
            scope["user"] = user
            scope["auth_error"] = None
        else:
            scope["user"] = AnonymousUser()
            scope["auth_error"] = auth_error

        return await self.inner(scope, receive, send)


def JwtAuthMiddlewareStack(inner):
    return JwtAuthMiddleware(inner)
