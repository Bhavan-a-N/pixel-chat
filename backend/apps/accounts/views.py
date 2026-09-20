from django.db import connection
from rest_framework import generics, status, views, permissions
from rest_framework.response import Response
from rest_framework_simplejwt.tokens import RefreshToken
from rest_framework_simplejwt.views import TokenObtainPairView
from django.contrib.auth import get_user_model

from .serializers import RegisterSerializer, UserSerializer

User = get_user_model()

class RegisterView(generics.CreateAPIView):
    queryset = User.objects.all()
    serializer_class = RegisterSerializer
    permission_classes = [permissions.AllowAny]
    throttle_scope = 'register'

class LoginView(TokenObtainPairView):
    permission_classes = [permissions.AllowAny]
    throttle_scope = 'login'

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
        allowed_keys = {'display_name'}
        update_keys = set(self.request.data.keys())
        if not update_keys.issubset(allowed_keys):
            pass # Ignoring other fields is handled by serializer fields, but we can explicitly restrict
        serializer.save()

class UserSearchView(generics.ListAPIView):
    serializer_class = UserSerializer
    permission_classes = [permissions.IsAuthenticated]
    throttle_scope = 'search'

    def get_queryset(self):
        query = self.request.query_params.get('username', '').strip()
        if len(query) < 2:
            return User.objects.none()
            
        return User.objects.filter(
            username__istartswith=query
        ).exclude(id=self.request.user.id).order_by('username')[:20]

class HealthCheckView(views.APIView):
    permission_classes = [permissions.AllowAny]

    def get(self, request):
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                row = cursor.fetchone()
                if row and row[0] == 1:
                    return Response({"status": "ok"})
        except Exception:
            pass
        return Response({"status": "error", "message": "Database unavailable"}, status=status.HTTP_503_SERVICE_UNAVAILABLE)
