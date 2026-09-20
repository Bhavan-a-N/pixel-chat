from django.urls import path
from rest_framework_simplejwt.views import TokenRefreshView
from .views import (
    RegisterView,
    LoginView,
    LogoutView,
    UserMeView,
    UserSearchView,
    HealthCheckView,
)

urlpatterns = [
    path("auth/register", RegisterView.as_view(), name="register"),
    path("auth/login", LoginView.as_view(), name="login"),
    path("auth/refresh", TokenRefreshView.as_view(), name="refresh"),
    path("auth/logout", LogoutView.as_view(), name="logout"),
    path("auth/me", UserMeView.as_view(), name="me"),
    path("users/search", UserSearchView.as_view(), name="user-search"),
    path("health", HealthCheckView.as_view(), name="health"),
]
