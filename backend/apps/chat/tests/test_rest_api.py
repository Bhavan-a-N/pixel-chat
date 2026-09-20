from django.contrib.auth import get_user_model
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
import pytest
from rest_framework import status
from rest_framework.test import APIClient

from apps.chat.services import get_or_create_dm, send_message

User = get_user_model()


@pytest.mark.django_db
class TestChatRestApi:
    @pytest.fixture(autouse=True)
    def setup_data(self):
        self.user1 = User.objects.create_user(
            email="alice@example.com",
            username="alice",
            password="Password123!",
        )
        self.user2 = User.objects.create_user(
            email="bob@example.com",
            username="bob",
            password="Password123!",
        )
        self.user3 = User.objects.create_user(
            email="charlie@example.com",
            username="charlie",
            password="Password123!",
        )

        self.client1 = APIClient()
        self.client1.force_authenticate(user=self.user1)

        self.client3 = APIClient()
        self.client3.force_authenticate(user=self.user3)

    def test_post_dm_success_and_idempotent(self):
        url = reverse("conversation-dm")

        # First creation
        res1 = self.client1.post(url, {"username": "bob"})
        assert res1.status_code == status.HTTP_200_OK
        data1 = res1.data
        assert data1["other_participant"]["username"] == "bob"
        assert data1["last_seq"] == 0

        # Idempotent re-creation (case-insensitive)
        res2 = self.client1.post(url, {"username": "BOB"})
        assert res2.status_code == status.HTTP_200_OK
        assert res2.data["id"] == data1["id"]

    def test_post_dm_cannot_dm_self(self):
        url = reverse("conversation-dm")
        res = self.client1.post(url, {"username": "alice"})
        assert res.status_code == status.HTTP_400_BAD_REQUEST

    def test_post_dm_unknown_user_404(self):
        url = reverse("conversation-dm")
        res = self.client1.post(url, {"username": "nonexistent"})
        assert res.status_code == status.HTTP_404_NOT_FOUND

    def test_get_conversations_list_query_count_does_not_grow(self):
        conv1, _ = get_or_create_dm(self.user1, self.user2)
        for i in range(5):
            send_message(self.user1, conv1.id, f"msg {i}", f"c1-{i}")

        url = reverse("conversation-list")

        with CaptureQueriesContext(connection) as ctx1:
            res1 = self.client1.get(url)
            assert res1.status_code == status.HTTP_200_OK
            count1 = len(ctx1.captured_queries)

        # Add another conversation with 50 messages
        conv2, _ = get_or_create_dm(self.user1, self.user3)
        for i in range(50):
            send_message(self.user3, conv2.id, f"msg {i}", f"c2-{i}")

        with CaptureQueriesContext(connection) as ctx2:
            res2 = self.client1.get(url)
            assert res2.status_code == status.HTTP_200_OK
            count2 = len(ctx2.captured_queries)

        assert (
            count1 == count2
        ), f"Query count grew from {count1} to {count2} with more conversations/messages"
        conv2.refresh_from_db()
        assert res2.data[0]["last_seq"] == conv2.next_seq - 1

    def test_messages_pagination_and_membership_check(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        # Non-member attempting to read messages gets 404
        url = reverse("conversation-messages", kwargs={"conversation_id": conv.id})
        res_non_member = self.client3.get(url)
        assert res_non_member.status_code == status.HTTP_404_NOT_FOUND

        # Send 10 messages
        for i in range(1, 11):
            send_message(
                user=self.user1 if i % 2 != 0 else self.user2,
                conversation_id=conv.id,
                body=f"Msg {i}",
                client_id=f"msg-{i}",
            )

        # 1. Default: latest first
        res_default = self.client1.get(url, {"limit": 5})
        assert res_default.status_code == status.HTTP_200_OK
        data_default = res_default.data
        assert len(data_default) == 5
        assert data_default[0]["seq"] == 10
        assert data_default[4]["seq"] == 6

        # 2. History before_seq
        res_before = self.client1.get(url, {"before_seq": 6, "limit": 3})
        assert res_before.status_code == status.HTTP_200_OK
        data_before = res_before.data
        assert len(data_before) == 3
        assert [m["seq"] for m in data_before] == [5, 4, 3]

        # 3. Catch-up after_seq (oldest first)
        res_after = self.client1.get(url, {"after_seq": 7, "limit": 5})
        assert res_after.status_code == status.HTTP_200_OK
        data_after = res_after.data
        assert len(data_after) == 3
        assert [m["seq"] for m in data_after] == [8, 9, 10]
