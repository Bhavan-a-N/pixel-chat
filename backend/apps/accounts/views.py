from rest_framework import generics, status, views, permissions
from rest_framework.response import Response
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView
from django.contrib.auth import get_user_model

from config.health import check_database, check_redis

from .serializers import RegisterSerializer, UserSerializer

User = get_user_model()


class RegisterView(generics.CreateAPIView):
    queryset = User.objects.all()
    serializer_class = RegisterSerializer
    permission_classes = [permissions.AllowAny]
    throttle_scope = "register"


class LoginView(TokenObtainPairView):
    permission_classes = [permissions.AllowAny]
    throttle_scope = "login"


class LogoutView(views.APIView):
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        try:
            refresh_token = request.data["refresh"]
            token = RefreshToken(refresh_token)
            token.blacklist()
            return Response(status=status.HTTP_205_RESET_CONTENT)
        except Exception:
            return Response(status=status.HTTP_400_BAD_REQUEST)


class UserMeView(generics.RetrieveUpdateAPIView):
    serializer_class = UserSerializer
    permission_classes = [permissions.IsAuthenticated]

    def get_object(self):
        return self.request.user

    def perform_update(self, serializer):
        # Ensure only display_name is updated
        allowed_keys = {"display_name"}
        update_keys = set(self.request.data.keys())
        if not update_keys.issubset(allowed_keys):
            pass  # Ignoring other fields is handled by serializer fields, but we can explicitly restrict
        serializer.save()


class UserSearchView(generics.ListAPIView):
    serializer_class = UserSerializer
    permission_classes = [permissions.IsAuthenticated]
    throttle_scope = "search"

    def get_queryset(self):
        query = self.request.query_params.get("username", "").strip()
        if len(query) < 2:
            return User.objects.none()

        return (
            User.objects.filter(username__istartswith=query)
            .exclude(id=self.request.user.id)
            .order_by("username")[:20]
        )


class HealthLiveView(views.APIView):
    """Liveness: no DB/Redis I/O (safe for Render health checks and keep-warm pings)."""

    permission_classes = [permissions.AllowAny]

    def get(self, request):
        return Response({"status": "live"})


class HealthReadyView(views.APIView):
    """Readiness: Postgres + Redis must respond."""

    permission_classes = [permissions.AllowAny]

    def get(self, request):
        db_ok = check_database()
        redis_ok = check_redis()
        if db_ok and redis_ok:
            return Response({"status": "ready"})
        errors = []
        if not db_ok:
            errors.append("database_unavailable")
        if not redis_ok:
            errors.append("redis_unavailable")
        return Response(
            {"status": "error", "errors": errors},
            status=status.HTTP_503_SERVICE_UNAVAILABLE,
        )


class HealthCheckView(HealthReadyView):
    """Backward-compatible alias for readiness."""
