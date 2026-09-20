import concurrent.futures
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import connection
import pytest

from apps.chat.models import Conversation, Membership
from apps.chat.services import (
    ClientIdMismatchError,
    get_or_create_dm,
    send_message,
)

User = get_user_model()


@pytest.mark.django_db
class TestChatModelsAndServices:
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

    def test_get_or_create_dm_idempotent(self):
        conv1, created1 = get_or_create_dm(self.user1, self.user2)
        assert created1 is True
        assert conv1.type == Conversation.TYPE_DM
        assert Membership.objects.filter(conversation=conv1).count() == 2

        # Reverse order returns exact same conversation
        conv2, created2 = get_or_create_dm(self.user2, self.user1)
        assert created2 is False
        assert conv1.id == conv2.id

    def test_cannot_dm_self(self):
        with pytest.raises(ValidationError):
            get_or_create_dm(self.user1, self.user1)

    def test_send_message_increments_seq_and_updates_timestamp(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        initial_updated_at = conv.updated_at

        msg1, is_new1 = send_message(
            user=self.user1,
            conversation_id=conv.id,
            body="First message",
            client_id="client-1",
        )
        assert is_new1 is True
        assert msg1.seq == 1
        conv.refresh_from_db()
        assert conv.next_seq == 2
        assert conv.updated_at >= initial_updated_at

        msg2, is_new2 = send_message(
            user=self.user2,
            conversation_id=conv.id,
            body="Second message",
            client_id="client-2",
        )
        assert is_new2 is True
        assert msg2.seq == 2
        conv.refresh_from_db()
        assert conv.next_seq == 3

    def test_duplicate_client_id_returns_same_message_no_new_seq(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        msg1, is_new1 = send_message(
            user=self.user1,
            conversation_id=conv.id,
            body="Original message",
            client_id="dup-1",
        )
        assert is_new1 is True
        assert msg1.seq == 1

        conv.refresh_from_db()
        assert conv.next_seq == 2

        # Resend with same client_id
        msg2, is_new2 = send_message(
            user=self.user1,
            conversation_id=conv.id,
            body="Attempted duplicate",
            client_id="dup-1",
        )
        assert is_new2 is False
        assert msg2.id == msg1.id
        assert msg2.seq == 1

        conv.refresh_from_db()
        assert conv.next_seq == 2  # Seq not consumed!

    def test_client_id_in_different_conversation_raises_error(self):
        conv1, _ = get_or_create_dm(self.user1, self.user2)
        conv2, _ = get_or_create_dm(self.user1, self.user3)

        send_message(
            user=self.user1,
            conversation_id=conv1.id,
            body="In Conv 1",
            client_id="cross-conv-id",
        )

        with pytest.raises(ClientIdMismatchError):
            send_message(
                user=self.user1,
                conversation_id=conv2.id,
                body="In Conv 2 with same client_id",
                client_id="cross-conv-id",
            )

    def test_non_member_cannot_send_message(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        with pytest.raises(PermissionDenied):
            send_message(
                user=self.user3,
                conversation_id=conv.id,
                body="Intruder",
                client_id="intruder-1",
            )

    def test_empty_or_oversize_body_rejected(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        with pytest.raises(ValidationError):
            send_message(self.user1, conv.id, "   ", "empty-1")

        with pytest.raises(ValidationError):
            send_message(self.user1, conv.id, "a" * 4001, "large-1")


@pytest.mark.django_db(transaction=True)
class TestConcurrentSendsMonotonicity:
    def test_concurrent_sends_produce_gapless_unique_seqs(self):
        user1 = User.objects.create_user(
            email="c1@example.com",
            username="c1",
            password="pw",
        )
        user2 = User.objects.create_user(
            email="c2@example.com",
            username="c2",
            password="pw",
        )
        conv, _ = get_or_create_dm(user1, user2)

        num_messages = 10

        def do_send(index: int):
            connection.close()
            sender = user1 if index % 2 == 0 else user2
            msg, _ = send_message(
                user=sender,
                conversation_id=conv.id,
                body=f"Message {index}",
                client_id=f"concurrent-{index}",
            )
            return msg.seq

        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
            futures = [executor.submit(do_send, i) for i in range(num_messages)]
            seqs = [f.result() for f in concurrent.futures.as_completed(futures)]

        assert len(seqs) == num_messages
        assert sorted(seqs) == list(
            range(1, num_messages + 1)
        ), f"Expected gapless seqs 1..{num_messages}, got {sorted(seqs)}"

    def test_concurrent_dm_creates_yield_one_conversation(self):
        user_a = User.objects.create_user(
            email="dma@example.com",
            username="dma",
            password="pw",
        )
        user_b = User.objects.create_user(
            email="dmb@example.com",
            username="dmb",
            password="pw",
        )

        def do_create(index: int):
            connection.close()
            # Alternate parameter ordering to test both directions concurrently
            if index % 2 == 0:
                conv, _ = get_or_create_dm(user_a, user_b)
            else:
                conv, _ = get_or_create_dm(user_b, user_a)
            return str(conv.id)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(do_create, i) for i in range(8)]
            conv_ids = [f.result() for f in concurrent.futures.as_completed(futures)]

        # All concurrent creations must resolve to the identical conversation ID
        assert len(set(conv_ids)) == 1
        assert Conversation.objects.filter(type=Conversation.TYPE_DM).count() >= 1
