from django.contrib import admin
from django.urls import path, include
from apps.accounts.views import HealthCheckView

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('apps.accounts.urls')),
    path('health', HealthCheckView.as_view(), name='health-root'),
]
