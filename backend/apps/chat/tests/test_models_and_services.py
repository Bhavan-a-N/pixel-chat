import concurrent.futures
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import connection
import pytest

from apps.chat.models import Conversation, Membership
from apps.chat.services import (
    ClientIdMismatchError,
    InvalidSeqError,
    NotAMemberError,
    get_or_create_dm,
    send_message,
    update_membership_pointer,
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
            try:
                sender = user1 if index % 2 == 0 else user2
                msg, _ = send_message(
                    user=sender,
                    conversation_id=conv.id,
                    body=f"Message {index}",
                    client_id=f"concurrent-{index}",
                )
                return msg.seq
            finally:
                connection.close()

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
            try:
                # Alternate parameter ordering to test both directions concurrently
                if index % 2 == 0:
                    conv, _ = get_or_create_dm(user_a, user_b)
                else:
                    conv, _ = get_or_create_dm(user_b, user_a)
                return str(conv.id)
            finally:
                connection.close()

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            futures = [executor.submit(do_create, i) for i in range(8)]
            conv_ids = [f.result() for f in concurrent.futures.as_completed(futures)]

        # All concurrent creations must resolve to the identical conversation ID
        assert len(set(conv_ids)) == 1
        assert Conversation.objects.filter(type=Conversation.TYPE_DM).count() >= 1


@pytest.mark.django_db(transaction=True)
class TestMembershipPointerUpdates:
    @pytest.fixture(autouse=True)
    def setup_data(self):
        self.user1 = User.objects.create_user(
            email="alice_ack@example.com",
            username="alice_ack",
            password="Password123!",
        )
        self.user2 = User.objects.create_user(
            email="bob_ack@example.com",
            username="bob_ack",
            password="Password123!",
        )
        self.user3 = User.objects.create_user(
            email="charlie_ack@example.com",
            username="charlie_ack",
            password="Password123!",
        )

    def test_update_pointer_forward_only_and_stale_ignored(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        send_message(self.user1, conv.id, "Hello 1", "c-1")
        send_message(self.user1, conv.id, "Hello 2", "c-2")
        send_message(self.user1, conv.id, "Hello 3", "c-3")

        # Advance delivered pointer to seq 2
        updated, d_seq, r_seq = update_membership_pointer(
            user=self.user2,
            conversation_id=conv.id,
            status_type="delivered",
            seq=2,
        )
        assert updated is True
        assert d_seq == 2
        assert r_seq == 0

        # Stale delivered ack (seq 1 < 2) is ignored silently, returns updated=False
        updated_stale, d_seq2, r_seq2 = update_membership_pointer(
            user=self.user2,
            conversation_id=conv.id,
            status_type="delivered",
            seq=1,
        )
        assert updated_stale is False
        assert d_seq2 == 2
        assert r_seq2 == 0

        m = Membership.objects.get(conversation=conv, user=self.user2)
        assert m.last_delivered_seq == 2
        assert m.last_read_seq == 0

    def test_update_pointer_out_of_order_acks(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        for i in range(1, 6):
            send_message(self.user1, conv.id, f"Msg {i}", f"c-{i}")

        # Out-of-order: ack 5 first, then ack 3
        updated5, d5, _ = update_membership_pointer(self.user2, conv.id, "delivered", 5)
        assert updated5 is True
        assert d5 == 5

        updated3, d3, _ = update_membership_pointer(self.user2, conv.id, "delivered", 3)
        assert updated3 is False
        assert d3 == 5

        m = Membership.objects.get(conversation=conv, user=self.user2)
        assert m.last_delivered_seq == 5

    def test_read_raises_delivered_invariant(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        for i in range(1, 6):
            send_message(self.user1, conv.id, f"Msg {i}", f"c-{i}")

        # Read ack 4 when delivered is 0: delivered must be raised to at least 4
        updated, d_seq, r_seq = update_membership_pointer(
            user=self.user2,
            conversation_id=conv.id,
            status_type="read",
            seq=4,
        )
        assert updated is True
        assert r_seq == 4
        assert d_seq == 4

        m = Membership.objects.get(conversation=conv, user=self.user2)
        assert m.last_read_seq == 4
        assert m.last_delivered_seq == 4

    def test_update_pointer_rejects_non_positive_and_beyond_max_seq(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        send_message(self.user1, conv.id, "Msg 1", "c-1")
        send_message(self.user1, conv.id, "Msg 2", "c-2")

        # 1. Non-positive seq (<= 0)
        with pytest.raises(InvalidSeqError):
            update_membership_pointer(self.user2, conv.id, "delivered", 0)

        with pytest.raises(InvalidSeqError):
            update_membership_pointer(self.user2, conv.id, "delivered", -5)

        # 2. Beyond max seq (conv max is 2)
        with pytest.raises(InvalidSeqError):
            update_membership_pointer(self.user2, conv.id, "delivered", 3)

    def test_update_pointer_rejects_non_member(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        send_message(self.user1, conv.id, "Msg 1", "c-1")

        with pytest.raises(NotAMemberError):
            update_membership_pointer(self.user3, conv.id, "delivered", 1)

    def test_concurrent_acks_end_at_max_value(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)
        total_msgs = 20
        for i in range(1, total_msgs + 1):
            send_message(self.user1, conv.id, f"Msg {i}", f"c-{i}")

        def do_ack(seq_num: int):
            try:
                update_membership_pointer(
                    user=self.user2,
                    conversation_id=conv.id,
                    status_type="read" if seq_num % 2 == 0 else "delivered",
                    seq=seq_num,
                )
            finally:
                connection.close()

        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
            futures = [executor.submit(do_ack, i) for i in range(1, total_msgs + 1)]
            for f in concurrent.futures.as_completed(futures):
                f.result()

        m = Membership.objects.get(conversation=conv, user=self.user2)
        assert m.last_delivered_seq == total_msgs
        # Highest even number <= 20 is 20
        assert m.last_read_seq == total_msgs
