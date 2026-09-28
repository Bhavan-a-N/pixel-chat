from django.contrib import admin
from django.urls import path, include
from apps.accounts.views import HealthCheckView, HealthLiveView, HealthReadyView

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/", include("apps.accounts.urls")),
    path("api/", include("apps.chat.urls")),
    path("health/live", HealthLiveView.as_view(), name="health-live-root"),
    path("health/ready", HealthReadyView.as_view(), name="health-ready-root"),
    path("health", HealthCheckView.as_view(), name="health-root"),
]
