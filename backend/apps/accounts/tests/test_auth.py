from unittest.mock import MagicMock, patch

import pytest
from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework import status
from django.contrib.auth import get_user_model
from django.db.utils import OperationalError

User = get_user_model()


@pytest.fixture
def api_client():
    return APIClient()


@pytest.fixture
def mock_env(monkeypatch):
    monkeypatch.setenv("INVITE_CODE", "testcode123")


@pytest.fixture(autouse=True)
def disable_throttling(settings):
    settings.REST_FRAMEWORK = {
        **settings.REST_FRAMEWORK,
        "DEFAULT_THROTTLE_CLASSES": [],
    }


@pytest.mark.django_db
class TestRegistration:
    def test_register_success(self, api_client, mock_env):
        url = reverse("register")
        data = {
            "email": "test@example.com",
            "username": "testuser",
            "password": "StrongPassword123!",
            "display_name": "Test User",
            "invite_code": "testcode123",
        }
        response = api_client.post(url, data)
        assert response.status_code == status.HTTP_201_CREATED
        assert "password" not in response.data
        assert User.objects.filter(email="test@example.com").exists()

    def test_wrong_invite_code(self, api_client, mock_env):
        url = reverse("register")
        data = {
            "email": "test@example.com",
            "username": "testuser",
            "password": "StrongPassword123!",
            "display_name": "Test User",
            "invite_code": "wrongcode",
        }
        response = api_client.post(url, data)
        assert response.status_code == status.HTTP_400_BAD_REQUEST
        assert "Invalid invite code" in str(response.data)

    def test_duplicate_email_case_insensitive(self, api_client, mock_env):
        User.objects.create_user(
            email="test@example.com", username="test1", password="pw"
        )
        url = reverse("register")
        data = {
            "email": "TEST@example.com",
            "username": "testuser2",
            "password": "StrongPassword123!",
            "invite_code": "testcode123",
        }
        response = api_client.post(url, data)
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_duplicate_username_case_insensitive(self, api_client, mock_env):
        User.objects.create_user(
            email="test1@example.com", username="Bob", password="pw"
        )
        url = reverse("register")
        data = {
            "email": "test2@example.com",
            "username": "bob",
            "password": "StrongPassword123!",
            "invite_code": "testcode123",
        }
        response = api_client.post(url, data)
        assert response.status_code == status.HTTP_400_BAD_REQUEST

    def test_username_validation(self, api_client, mock_env):
        url = reverse("register")
        # Too short
        data = {
            "email": "t@t.com",
            "username": "ab",
            "password": "StrongPassword123!",
            "invite_code": "testcode123",
        }
        assert api_client.post(url, data).status_code == status.HTTP_400_BAD_REQUEST

        # Invalid chars
        data["username"] = "bob@hello"
        assert api_client.post(url, data).status_code == status.HTTP_400_BAD_REQUEST

    def test_password_validation(self, api_client, mock_env):
        url = reverse("register")
        data = {
            "email": "t@t.com",
            "username": "bob123",
            "password": "123",
            "invite_code": "testcode123",
        }
        response = api_client.post(url, data)
        assert response.status_code == status.HTTP_400_BAD_REQUEST
        assert "password" in response.data["error"]["details"]


@pytest.mark.django_db
class TestLogin:
    @pytest.fixture(autouse=True)
    def setup_user(self):
        self.user = User.objects.create_user(
            email="user@example.com", username="user1", password="Password123!"
        )

    def test_login_success(self, api_client):
        url = reverse("login")
        response = api_client.post(
            url, {"email": "user@example.com", "password": "Password123!"}
        )
        assert response.status_code == status.HTTP_200_OK
        assert "access" in response.data
        assert "refresh" in response.data

    def test_login_failure_hides_email_existence(self, api_client):
        url = reverse("login")
        # Wrong password
        res1 = api_client.post(
            url, {"email": "user@example.com", "password": "WrongPassword!"}
        )
        assert res1.status_code == status.HTTP_401_UNAUTHORIZED
        assert res1.data["error"]["details"]["detail"] == "Invalid credentials."

        # Wrong email
        res2 = api_client.post(
            url, {"email": "nobody@example.com", "password": "Password123!"}
        )
        assert res2.status_code == status.HTTP_401_UNAUTHORIZED
        assert res2.data["error"]["details"]["detail"] == "Invalid credentials."


@pytest.mark.django_db
class TestTokenRotation:
    def test_refresh_rotation_and_blacklist(self, api_client):
        User.objects.create_user(
            email="user@example.com", username="user1", password="Password123!"
        )
        login_res = api_client.post(
            reverse("login"), {"email": "user@example.com", "password": "Password123!"}
        )
        old_refresh = login_res.data["refresh"]

        # Refresh
        refresh_res = api_client.post(reverse("refresh"), {"refresh": old_refresh})
        assert refresh_res.status_code == status.HTTP_200_OK
        new_refresh = refresh_res.data["refresh"]
        assert new_refresh != old_refresh

        # Try to use old refresh again
        failed_res = api_client.post(reverse("refresh"), {"refresh": old_refresh})
        assert failed_res.status_code == status.HTTP_401_UNAUTHORIZED

    def test_logout(self, api_client):
        User.objects.create_user(
            email="user@example.com", username="user1", password="Password123!"
        )
        login_res = api_client.post(
            reverse("login"), {"email": "user@example.com", "password": "Password123!"}
        )

        api_client.credentials(HTTP_AUTHORIZATION="Bearer " + login_res.data["access"])
        logout_res = api_client.post(
            reverse("logout"), {"refresh": login_res.data["refresh"]}
        )
        assert logout_res.status_code == status.HTTP_205_RESET_CONTENT

        # Refresh token should now be invalid
        refresh_res = api_client.post(
            reverse("refresh"), {"refresh": login_res.data["refresh"]}
        )
        assert refresh_res.status_code == status.HTTP_401_UNAUTHORIZED


@pytest.mark.django_db
class TestUserSearchAndProfile:
    def test_unauthorized_access(self, api_client):
        assert api_client.get(reverse("me")).status_code == status.HTTP_401_UNAUTHORIZED
        assert (
            api_client.get(reverse("user-search")).status_code
            == status.HTTP_401_UNAUTHORIZED
        )

    def test_search_never_leaks_email(self, api_client):
        User.objects.create_user(
            email="u1@example.com", username="alice", password="pw"
        )
        User.objects.create_user(
            email="u2@example.com", username="alicia", password="pw"
        )

        # Login as user1
        token = api_client.post(
            reverse("login"), {"email": "u1@example.com", "password": "pw"}
        ).data["access"]
        api_client.credentials(HTTP_AUTHORIZATION="Bearer " + token)

        res = api_client.get(reverse("user-search") + "?username=ali")
        assert res.status_code == status.HTTP_200_OK
        assert len(res.data) == 1
        assert res.data[0]["username"] == "alicia"
        assert "email" not in res.data[0]


@pytest.mark.django_db
class TestHealthCheck:
    def test_health_live_always_ok(self, api_client):
        res = api_client.get(reverse("health-live-root"))
        assert res.status_code == status.HTTP_200_OK
        assert res.data["status"] == "live"

    def test_health_ready_success(self, api_client):
        res = api_client.get(reverse("health-ready-root"))
        assert res.status_code == status.HTTP_200_OK
        assert res.data["status"] == "ready"

    def test_health_alias_matches_ready(self, api_client):
        res = api_client.get(reverse("health-root"))
        assert res.status_code == status.HTTP_200_OK
        assert res.data["status"] == "ready"

    @patch("apps.accounts.views.check_database")
    def test_health_ready_db_failure(self, mock_db, api_client):
        mock_db.return_value = False
        res = api_client.get(reverse("health-ready-root"))
        assert res.status_code == status.HTTP_503_SERVICE_UNAVAILABLE
        assert "database_unavailable" in res.data["errors"]

    @patch("apps.accounts.views.check_redis")
    def test_health_ready_redis_failure(self, mock_redis, api_client):
        mock_redis.return_value = False
        res = api_client.get(reverse("health-ready-root"))
        assert res.status_code == status.HTTP_503_SERVICE_UNAVAILABLE
        assert "redis_unavailable" in res.data["errors"]

    # transaction=True: no wrapping atomic block, so connection.close() fully
    # drops the connection and the readiness check must reconnect (mirrors
    # a Neon/PgBouncer dropped connection in production).
    @pytest.mark.django_db(transaction=True)
    def test_health_ready_recovers_after_db_connection_closed(self, api_client):
        from django.db import connection

        connection.ensure_connection()
        connection.close()
        res = api_client.get(reverse("health-ready-root"))
        assert res.status_code == status.HTTP_200_OK

    @patch("config.health.connection")
    def test_check_database_retries_after_stale_connection(self, mock_conn):
        from config.health import check_database

        ok_cursor = MagicMock()
        ok_cursor.__enter__.return_value = ok_cursor
        ok_cursor.fetchone.return_value = (1,)
        mock_conn.in_atomic_block = False
        mock_conn.cursor.side_effect = [
            OperationalError("server closed the connection unexpectedly"),
            ok_cursor,
        ]

        assert check_database() is True
        assert mock_conn.close.call_count == 1


@pytest.mark.django_db
class TestThrottling:
    @patch("rest_framework.throttling.ScopedRateThrottle.get_rate")
    def test_throttle_triggers(self, mock_get_rate, api_client):
        mock_get_rate.return_value = "2/min"
        from apps.accounts.views import LoginView
        from rest_framework.throttling import ScopedRateThrottle

        original_classes = LoginView.throttle_classes
        LoginView.throttle_classes = [ScopedRateThrottle]
        try:
            url = reverse("login")
            api_client.post(url, {"email": "u1@example.com", "password": "pw"})
            api_client.post(url, {"email": "u1@example.com", "password": "pw"})
            res = api_client.post(url, {"email": "u1@example.com", "password": "pw"})
            assert res.status_code == status.HTTP_429_TOO_MANY_REQUESTS
        finally:
            LoginView.throttle_classes = original_classes
