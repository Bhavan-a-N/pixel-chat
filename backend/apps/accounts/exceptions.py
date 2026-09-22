from django.core.exceptions import (
    PermissionDenied as DjangoPermissionDenied,
    ValidationError as DjangoValidationError,
)
from rest_framework import exceptions
from rest_framework.views import exception_handler


def custom_exception_handler(exc, context):
    if isinstance(exc, DjangoValidationError):
        detail = exc.messages if hasattr(exc, "messages") else [str(exc)]
        exc = exceptions.ValidationError(detail=detail)
    elif isinstance(exc, DjangoPermissionDenied):
        exc = exceptions.PermissionDenied(detail=str(exc))

    response = exception_handler(exc, context)

    if response is not None:
        custom_data = {
            "error": {
                "code": response.status_code,
                "message": getattr(response, "status_text", exc.__class__.__name__),
                "details": response.data,
            }
        }

        # Consistent generic message for login failure to prevent enumeration
        if response.status_code == 401 and "No active account found" in str(
            response.data
        ):
            custom_data["error"]["message"] = "Authentication Failed"
            custom_data["error"]["details"] = {"detail": "Invalid credentials."}

        response.data = custom_data

    return response
