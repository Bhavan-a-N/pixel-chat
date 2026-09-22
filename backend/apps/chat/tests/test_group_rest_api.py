import pytest
from django.contrib.auth import get_user_model
from django.db import connection
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from django.core.cache import cache

from apps.chat.models import Conversation, Membership, Message
from apps.chat.services import (
    create_group,
    send_message,
)

User = get_user_model()


@pytest.mark.django_db
class TestGroupRestApi:
    @pytest.fixture(autouse=True)
    def setup_data(self):
        self.alice = User.objects.create_user(
            email="alice@example.com",
            username="alice",
            password="Password123!",
            display_name="Alice A",
            avatar_seed="alice-seed",
        )
        self.bob = User.objects.create_user(
            email="bob@example.com",
            username="bob",
            password="Password123!",
            display_name="Bob B",
            avatar_seed="bob-seed",
        )
        self.charlie = User.objects.create_user(
            email="charlie@example.com",
            username="charlie",
            password="Password123!",
            display_name="Charlie C",
            avatar_seed="charlie-seed",
        )
        self.david = User.objects.create_user(
            email="david@example.com",
            username="david",
            password="Password123!",
            display_name="David D",
            avatar_seed="david-seed",
        )

        self.client_alice = APIClient()
        self.client_alice.force_authenticate(user=self.alice)

        self.client_bob = APIClient()
        self.client_bob.force_authenticate(user=self.bob)

        self.client_david = APIClient()
        self.client_david.force_authenticate(user=self.david)

    def test_create_group_success_and_validations(self):
        url = reverse("conversation-group-create")

        # 1. Success creation
        res = self.client_alice.post(
            url,
            {"name": "  Project Alpha  ", "members": ["bob", "charlie", "bob"]},
            format="json",
        )
        assert res.status_code == status.HTTP_201_CREATED
        data = res.data
        assert data["name"] == "Project Alpha"  # Trimmed
        assert data["type"] == "group"
        assert (
            len(data["memberships"]) == 3
        )  # Alice, Bob, Charlie (duplicate bob ignored)

        # Alice is admin
        alice_m = next(
            m for m in data["memberships"] if m["user_id"] == str(self.alice.id)
        )
        assert alice_m["role"] == "admin"
        bob_m = next(m for m in data["memberships"] if m["user_id"] == str(self.bob.id))
        assert bob_m["role"] == "member"

        # Check initial system message exists
        conv_id = data["id"]
        messages = Message.objects.filter(conversation_id=conv_id)
        assert messages.count() == 1
        sys_msg = messages.first()
        assert sys_msg.is_system is True
        assert sys_msg.system_data["kind"] == "group_created"

        # 2. Blank name rejected
        res_blank = self.client_alice.post(
            url,
            {"name": "   ", "members": ["bob"]},
            format="json",
        )
        assert res_blank.status_code == status.HTTP_400_BAD_REQUEST

        # 3. Name > 50 chars rejected
        res_long = self.client_alice.post(
            url,
            {"name": "a" * 51, "members": ["bob"]},
            format="json",
        )
        assert res_long.status_code == status.HTTP_400_BAD_REQUEST

        # 4. Unknown user rejected
        res_unknown = self.client_alice.post(
            url,
            {"name": "Valid Group", "members": ["nonexistent_user"]},
            format="json",
        )
        assert res_unknown.status_code == status.HTTP_400_BAD_REQUEST

    def test_group_detail_never_exposes_email(self):
        conv = create_group(self.alice, "Secret Club", [self.bob.id])
        url = reverse("conversation-detail", kwargs={"conversation_id": conv.id})

        res = self.client_bob.get(url)
        assert res.status_code == status.HTTP_200_OK
        data = res.data
        assert data["name"] == "Secret Club"
        assert len(data["members"]) == 2

        # Check fields of members and ensure email is nowhere in response
        res_text = res.content.decode("utf-8")
        assert "email" not in res_text
        assert "@example.com" not in res_text

        for m in data["members"]:
            assert "id" in m
            assert "username" in m
            assert "display_name" in m
            assert "avatar_seed" in m
            assert "role" in m
            assert "joined_at_seq" in m
            assert "last_delivered_seq" in m
            assert "last_read_seq" in m
            assert "email" not in m

    def test_group_non_member_access_returns_404(self):
        conv = create_group(self.alice, "Private Team", [self.bob.id])

        # David is not a member
        urls_and_methods = [
            (
                reverse("conversation-detail", kwargs={"conversation_id": conv.id}),
                "get",
                {},
            ),
            (
                reverse("conversation-detail", kwargs={"conversation_id": conv.id}),
                "patch",
                {"name": "Hacked"},
            ),
            (
                reverse("conversation-members", kwargs={"conversation_id": conv.id}),
                "post",
                {"members": ["david"]},
            ),
            (
                reverse(
                    "conversation-member-remove",
                    kwargs={"conversation_id": conv.id, "user_id": self.bob.id},
                ),
                "delete",
                {},
            ),
            (
                reverse(
                    "conversation-member-role",
                    kwargs={"conversation_id": conv.id, "user_id": self.bob.id},
                ),
                "patch",
                {"role": "admin"},
            ),
            (
                reverse("conversation-leave", kwargs={"conversation_id": conv.id}),
                "post",
                {},
            ),
            (
                reverse("conversation-messages", kwargs={"conversation_id": conv.id}),
                "get",
                {},
            ),
        ]

        for u, method, payload in urls_and_methods:
            if method == "get":
                res = self.client_david.get(u)
            elif method == "post":
                res = self.client_david.post(u, payload, format="json")
            elif method == "patch":
                res = self.client_david.patch(u, payload, format="json")
            elif method == "delete":
                res = self.client_david.delete(u)
            assert (
                res.status_code == status.HTTP_404_NOT_FOUND
            ), f"Expected 404 for {method} {u}, got {res.status_code}"

    def test_rename_group(self):
        conv = create_group(self.alice, "Initial Name", [self.bob.id])
        url = reverse("conversation-detail", kwargs={"conversation_id": conv.id})

        # 1. Non-admin (Bob) cannot rename -> 403
        res_bob = self.client_bob.patch(url, {"name": "Bob's Title"}, format="json")
        assert res_bob.status_code == status.HTTP_403_FORBIDDEN

        # 2. Admin (Alice) can rename
        res_alice = self.client_alice.patch(
            url, {"name": "  Renamed Title  "}, format="json"
        )
        assert res_alice.status_code == status.HTTP_200_OK
        assert res_alice.data["name"] == "Renamed Title"

        # Verify system message generated for rename
        last_msg = (
            Message.objects.filter(conversation_id=conv.id).order_by("-seq").first()
        )
        assert last_msg.is_system is True
        assert last_msg.system_data["kind"] == "group_renamed"
        assert "Renamed Title" in last_msg.body

    def test_add_and_remove_members(self):
        conv = create_group(self.alice, "Squad", [self.bob.id])
        add_url = reverse("conversation-members", kwargs={"conversation_id": conv.id})

        # 1. Non-admin (Bob) cannot add -> 403
        res_bob_add = self.client_bob.post(
            add_url, {"members": ["charlie"]}, format="json"
        )
        assert res_bob_add.status_code == status.HTTP_403_FORBIDDEN

        # 2. Admin adds Charlie (duplicates and existing members ignored)
        res_alice_add = self.client_alice.post(
            add_url,
            {"members": ["charlie", "bob", "charlie"]},
            format="json",
        )
        assert res_alice_add.status_code == status.HTTP_200_OK
        assert len(res_alice_add.data["members"]) == 3

        # 3. Non-admin (Bob) cannot remove -> 403
        remove_charlie_url = reverse(
            "conversation-member-remove",
            kwargs={"conversation_id": conv.id, "user_id": self.charlie.id},
        )
        res_bob_remove = self.client_bob.delete(remove_charlie_url)
        assert res_bob_remove.status_code == status.HTTP_403_FORBIDDEN

        # 4. Admin removes Charlie
        res_alice_remove = self.client_alice.delete(remove_charlie_url)
        assert res_alice_remove.status_code == status.HTTP_204_NO_CONTENT
        assert not Membership.objects.filter(
            conversation=conv, user=self.charlie
        ).exists()

    def test_role_change_promote_demote_and_last_admin(self):
        conv = create_group(self.alice, "Staff", [self.bob.id])
        bob_role_url = reverse(
            "conversation-member-role",
            kwargs={"conversation_id": conv.id, "user_id": self.bob.id},
        )
        alice_role_url = reverse(
            "conversation-member-role",
            kwargs={"conversation_id": conv.id, "user_id": self.alice.id},
        )

        # 1. Non-admin (Bob) cannot change roles -> 403
        res_bob = self.client_bob.patch(bob_role_url, {"role": "admin"}, format="json")
        assert res_bob.status_code == status.HTTP_403_FORBIDDEN

        # 2. Admin (Alice) promotes Bob to admin
        res_promote = self.client_alice.patch(
            bob_role_url, {"role": "admin"}, format="json"
        )
        assert res_promote.status_code == status.HTTP_200_OK
        assert res_promote.data["role"] == "admin"

        # 3. Bob (now admin) demotes Alice to member
        res_demote_alice = self.client_bob.patch(
            alice_role_url, {"role": "member"}, format="json"
        )
        assert res_demote_alice.status_code == status.HTTP_200_OK
        assert res_demote_alice.data["role"] == "member"

        # 4. Bob tries to demote himself (he is the last admin) -> 400
        res_demote_last = self.client_bob.patch(
            bob_role_url, {"role": "member"}, format="json"
        )
        assert res_demote_last.status_code == status.HTTP_400_BAD_REQUEST

    def test_leave_group_and_empty_group_deletion(self):
        conv = create_group(self.alice, "Solo Group", [])
        leave_url = reverse("conversation-leave", kwargs={"conversation_id": conv.id})

        # Sole member is Alice (admin). Leaving deletes the group in the same transaction!
        res_leave = self.client_alice.post(leave_url)
        assert res_leave.status_code == status.HTTP_200_OK
        assert res_leave.data["deleted"] is True
        assert not Conversation.objects.filter(id=conv.id).exists()

    def test_history_visibility_and_join_point(self):
        # Alice creates group alone
        conv = create_group(self.alice, "JoinPoint Group", [])

        # Alice sends 5 messages (seq 2, 3, 4, 5, 6 - seq 1 was group_created)
        for i in range(1, 6):
            send_message(self.alice, conv.id, f"Alice msg {i}", f"c-alice-{i}")

        # Alice adds Bob -> Bob's joined_at_seq is conv.next_seq - 1 (seq 6)
        # and "added" system message is seq 7
        add_url = reverse("conversation-members", kwargs={"conversation_id": conv.id})
        res_add = self.client_alice.post(add_url, {"members": ["bob"]}, format="json")
        assert res_add.status_code == status.HTTP_200_OK

        bob_membership = Membership.objects.get(conversation=conv, user=self.bob)
        assert bob_membership.joined_at_seq == 6

        # Bob requests messages
        messages_url = reverse(
            "conversation-messages", kwargs={"conversation_id": conv.id}
        )
        res_bob_msgs = self.client_bob.get(messages_url)
        assert res_bob_msgs.status_code == status.HTTP_200_OK
        # Bob should ONLY see seq 7 ("Alice added Bob") and NOT seq 1..6
        assert len(res_bob_msgs.data) == 1
        assert res_bob_msgs.data[0]["seq"] == 7
        assert res_bob_msgs.data[0]["is_system"] is True

        # Bob attempts before_seq=7 -> should get empty list because joined_at_seq is 6
        res_bob_before = self.client_bob.get(messages_url, {"before_seq": 7})
        assert res_bob_before.status_code == status.HTTP_200_OK
        assert len(res_bob_before.data) == 0

        # Conversation list preview for Bob shows the system message (seq 7), not the old ones
        list_url = reverse("conversation-list")
        res_bob_list = self.client_bob.get(list_url)
        assert res_bob_list.status_code == status.HTTP_200_OK
        assert len(res_bob_list.data) == 1
        conv_summary = res_bob_list.data[0]
        assert conv_summary["last_seq"] == 7
        assert conv_summary["last_message"] is not None
        assert conv_summary["last_message"]["seq"] == 7

    def test_ex_member_message_renders_with_display_name_and_avatar(self):
        conv = create_group(self.alice, "Alumni Group", [self.bob.id])
        # Bob sends a message
        msg, _ = send_message(self.bob, conv.id, "Farewell message", "bob-bye")

        # Bob leaves
        leave_url = reverse("conversation-leave", kwargs={"conversation_id": conv.id})
        self.client_bob.post(leave_url)

        # Alice fetches messages: Bob's message still carries Bob's display_name and avatar_seed
        messages_url = reverse(
            "conversation-messages", kwargs={"conversation_id": conv.id}
        )
        res_alice = self.client_alice.get(messages_url)
        assert res_alice.status_code == status.HTTP_200_OK

        bob_msg_item = next(m for m in res_alice.data if m["id"] == str(msg.id))
        assert bob_msg_item["sender_display_name"] == "Bob B"
        assert bob_msg_item["sender_avatar_seed"] == "bob-seed"

    def test_group_conversation_list_query_count_is_flat(self):
        # Create multiple groups and DMs with messages
        conv1 = create_group(self.alice, "Group 1", [self.bob.id])
        for i in range(5):
            send_message(self.alice, conv1.id, f"msg {i}", f"c1-{i}")

        list_url = reverse("conversation-list")

        with CaptureQueriesContext(connection) as ctx1:
            res1 = self.client_alice.get(list_url)
            assert res1.status_code == status.HTTP_200_OK
            count1 = len(ctx1.captured_queries)

        # Add another group with more members and messages
        conv2 = create_group(self.alice, "Group 2", [self.bob.id, self.charlie.id])
        for i in range(20):
            send_message(self.bob, conv2.id, f"msg {i}", f"c2-{i}")

        with CaptureQueriesContext(connection) as ctx2:
            res2 = self.client_alice.get(list_url)
            assert res2.status_code == status.HTTP_200_OK
            count2 = len(ctx2.captured_queries)

        assert (
            count1 == count2
        ), f"Query count grew from {count1} to {count2} with more group conversations and messages"

    def test_user_presence_endpoint_scoped_to_mutual_conversations(self):
        # Set online presence in Redis
        cache.set(f"presence:user:{self.bob.id}", 1, timeout=60)
        cache.set(f"presence:user:{self.david.id}", 1, timeout=60)

        presence_url = reverse("user-presence")
        query_param = {"user_ids": f"{self.bob.id},{self.david.id}"}

        # Before Alice shares any conversation with Bob or David
        res_alice_init = self.client_alice.get(presence_url, query_param)
        assert res_alice_init.status_code == status.HTTP_200_OK
        # Alice shares nothing, so neither Bob nor David are in presence dict
        assert str(self.bob.id) not in res_alice_init.data
        assert str(self.david.id) not in res_alice_init.data

        # Alice creates a group with Bob
        conv = create_group(self.alice, "Mutual Group", [self.bob.id])

        # Alice checks presence again -> Bob is online, David is not shared
        res_alice_group = self.client_alice.get(presence_url, query_param)
        assert res_alice_group.status_code == status.HTTP_200_OK
        assert str(self.bob.id) in res_alice_group.data
        assert res_alice_group.data[str(self.bob.id)] is True
        assert str(self.david.id) not in res_alice_group.data

        # Remove Bob from group
        remove_url = reverse(
            "conversation-member-remove",
            kwargs={"conversation_id": conv.id, "user_id": self.bob.id},
        )
        self.client_alice.delete(remove_url)

        # Alice checks presence -> Bob is no longer in scope
        res_alice_after = self.client_alice.get(presence_url, query_param)
        assert str(self.bob.id) not in res_alice_after.data

    def test_readded_member_receives_nothing_older_than_new_join_point(self):
        # 1. Alice creates group with Bob (seq 1: group_created)
        conv = create_group(self.alice, "Readd Visibility Group", [self.bob.username])

        # 2. Bob sends a message, Alice sends a message (seq 2, 3)
        send_message(self.bob, conv.id, "Bob initial message", "c-bob-init")
        send_message(self.alice, conv.id, "Alice reply 1", "c-alice-1")

        # 3. Alice removes Bob (seq 4: member_removed)
        remove_url = reverse(
            "conversation-member-remove",
            kwargs={"conversation_id": conv.id, "user_id": self.bob.id},
        )
        res_remove = self.client_alice.delete(remove_url)
        assert res_remove.status_code == status.HTTP_204_NO_CONTENT

        # 4. Alice sends messages while Bob is removed (seq 5, 6)
        send_message(self.alice, conv.id, "Secret message while Bob away 1", "c-alice-away-1")
        send_message(self.alice, conv.id, "Secret message while Bob away 2", "c-alice-away-2")

        # 5. Alice re-adds Bob (Bob joined_at_seq is 6, seq 7 is member_added system msg)
        add_url = reverse("conversation-members", kwargs={"conversation_id": conv.id})
        res_add = self.client_alice.post(add_url, {"members": [self.bob.username]}, format="json")
        assert res_add.status_code == status.HTTP_200_OK

        bob_m = Membership.objects.get(conversation=conv, user=self.bob)
        assert bob_m.joined_at_seq == 6

        messages_url = reverse(
            "conversation-messages", kwargs={"conversation_id": conv.id}
        )

        # 6. Bob calls GET /messages -> must only return messages with seq > 6
        res_bob_msgs = self.client_bob.get(messages_url)
        assert res_bob_msgs.status_code == status.HTTP_200_OK
        # Bob receives ONLY the new member_added system message (seq 7)
        assert len(res_bob_msgs.data) == 1
        assert res_bob_msgs.data[0]["seq"] == 7
        assert res_bob_msgs.data[0]["seq"] > bob_m.joined_at_seq
        # Ensure no older messages (seq <= 6) returned, even though Bob was in group for seq 2, 3
        returned_seqs = [m["seq"] for m in res_bob_msgs.data]
        assert not any(s <= 6 for s in returned_seqs)

        # 7. Bob calls GET /messages?after_seq=0 (catch-up) -> receives nothing with seq <= 6
        res_catchup_0 = self.client_bob.get(messages_url, {"after_seq": 0})
        assert res_catchup_0.status_code == status.HTTP_200_OK
        assert len(res_catchup_0.data) == 1
        assert res_catchup_0.data[0]["seq"] == 7

        # 8. Bob attempts after_seq=2 (his old pre-removal message) -> receives nothing with seq <= 6
        res_catchup_old = self.client_bob.get(messages_url, {"after_seq": 2})
        assert res_catchup_old.status_code == status.HTTP_200_OK
        assert len(res_catchup_old.data) == 1
        assert res_catchup_old.data[0]["seq"] == 7

        # 9. Bob attempts before_seq=7 -> empty list (all older messages are <= joined_at_seq)
        res_before = self.client_bob.get(messages_url, {"before_seq": 7})
        assert res_before.status_code == status.HTTP_200_OK
        assert len(res_before.data) == 0

