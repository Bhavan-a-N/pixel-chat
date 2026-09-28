import threading
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import connection
from django.test import override_settings
import pytest

from apps.chat.models import Conversation, Membership
from apps.chat.services import (
    add_group_members,
    change_member_role,
    create_group,
    leave_group,
    remove_group_member,
    rename_group,
    send_message,
    update_membership_pointer,
)

User = get_user_model()


@pytest.mark.django_db(transaction=True)
class TestGroupServices:
    @pytest.fixture(autouse=True)
    def setup_users(self):
        self.alice = User.objects.create_user(
            email="alice@example.com",
            username="alice",
            display_name="Alice A",
            avatar_seed="seed-a",
            password="Password123!",
        )
        self.bob = User.objects.create_user(
            email="bob@example.com",
            username="bob",
            display_name="Bob B",
            avatar_seed="seed-b",
            password="Password123!",
        )
        self.charlie = User.objects.create_user(
            email="charlie@example.com",
            username="charlie",
            display_name="Charlie C",
            avatar_seed="seed-c",
            password="Password123!",
        )
        self.david = User.objects.create_user(
            email="david@example.com",
            username="david",
            display_name="David D",
            avatar_seed="seed-d",
            password="Password123!",
        )

    def test_create_group_validations_and_admin(self):
        # 1. Empty or whitespace name fails
        with pytest.raises(ValidationError, match="Group name cannot be empty"):
            create_group(self.alice, "   ", [self.bob.username])

        # 2. Name > 50 chars fails
        with pytest.raises(ValidationError, match="exceeds 50 characters"):
            create_group(self.alice, "A" * 51, [self.bob.username])

        # 3. Unknown user fails
        with pytest.raises(ValidationError, match="Unknown user"):
            create_group(self.alice, "Devs", ["nonexistent_user"])

        # 4. Success: name trimmed, duplicates ignored, creator auto-added as admin
        conv = create_group(
            self.alice,
            "  Devs Team  ",
            [
                self.bob.username,
                self.bob.username,
                self.charlie.id,
                self.alice.username,
            ],
        )

        assert conv.type == Conversation.TYPE_GROUP
        assert conv.name == "Devs Team"
        assert conv.dm_key is None

        memberships = {m.user_id: m for m in conv.memberships.all()}
        assert len(memberships) == 3  # alice, bob, charlie

        alice_m = memberships[self.alice.id]
        assert alice_m.role == Membership.ROLE_ADMIN
        assert alice_m.joined_at_seq == 0

        bob_m = memberships[self.bob.id]
        assert bob_m.role == Membership.ROLE_MEMBER
        assert bob_m.joined_at_seq == 0

        charlie_m = memberships[self.charlie.id]
        assert charlie_m.role == Membership.ROLE_MEMBER
        assert charlie_m.joined_at_seq == 0

        # Initial system message created
        assert conv.messages.count() == 1
        sys_msg = conv.messages.first()
        assert sys_msg.is_system is True
        assert sys_msg.system_data["kind"] == "group_created"
        assert "created the group" in sys_msg.body
        assert sys_msg.seq == 1
        assert conv.next_seq == 2

    @override_settings(GROUP_SIZE_CAP=3)
    def test_create_group_cap_enforced(self):
        # Alice + Bob + Charlie = 3 (allowed)
        conv = create_group(
            self.alice, "Small Group", [self.bob.username, self.charlie.username]
        )
        assert conv.memberships.count() == 3

        # Adding David exceeds cap (4 > 3)
        with pytest.raises(ValidationError, match="Group size cannot exceed 3"):
            create_group(
                self.alice,
                "Too Big",
                [self.bob.username, self.charlie.username, self.david.username],
            )

    def test_add_members_joined_at_seq_and_system_message(self):
        conv = create_group(self.alice, "Devs", [self.bob.username])
        # Send 3 messages
        send_message(self.alice, conv.id, "Msg 1", "c-1")
        send_message(self.bob, conv.id, "Msg 2", "c-2")
        send_message(self.alice, conv.id, "Msg 3", "c-3")

        conv.refresh_from_db()
        # Initial sys message seq 1 + 3 user messages = next_seq is 5
        assert conv.next_seq == 5

        # Add Charlie
        # Amendment 8: joined_at_seq computed BEFORE the "added" system message
        new_memberships = add_group_members(
            self.alice, conv.id, [self.charlie.username]
        )
        assert len(new_memberships) == 1
        charlie_m = new_memberships[0]

        assert charlie_m.joined_at_seq == 4  # conv.next_seq - 1 before system msg
        assert charlie_m.last_delivered_seq == 4
        assert charlie_m.last_read_seq == 4

        # System message seq should be 5
        conv.refresh_from_db()
        sys_msg = conv.messages.order_by("-seq").first()
        assert sys_msg.seq == 5
        assert sys_msg.is_system is True
        assert sys_msg.system_data["kind"] == "members_added"
        assert "added Charlie C" in sys_msg.body
        # Since charlie.joined_at_seq == 4, Charlie will see this system message (seq 5 > 4)!

    def test_readded_member_gets_new_join_point(self):
        conv = create_group(
            self.alice, "Devs", [self.bob.username, self.charlie.username]
        )
        send_message(self.alice, conv.id, "Welcome", "c-1")

        # Remove Charlie
        remove_group_member(self.alice, conv.id, self.charlie.id)
        assert not Membership.objects.filter(
            conversation=conv, user=self.charlie
        ).exists()

        # Send messages while Charlie is away
        send_message(self.alice, conv.id, "Secret while away 1", "c-2")
        send_message(self.bob, conv.id, "Secret while away 2", "c-3")

        conv.refresh_from_db()
        away_seq = conv.next_seq - 1

        # Re-add Charlie
        add_group_members(self.alice, conv.id, [self.charlie.username])
        charlie_m = Membership.objects.get(conversation=conv, user=self.charlie)

        # Charlie's new joined_at_seq is at the re-add point
        assert charlie_m.joined_at_seq == away_seq
        assert charlie_m.last_delivered_seq == away_seq
        assert charlie_m.last_read_seq == away_seq

    def test_admin_only_add_remove_rename_role(self):
        conv = create_group(
            self.alice, "Devs", [self.bob.username, self.charlie.username]
        )

        # Bob is member, not admin
        with pytest.raises(PermissionDenied, match="Only admins"):
            add_group_members(self.bob, conv.id, [self.david.username])

        with pytest.raises(PermissionDenied, match="Only admins"):
            remove_group_member(self.bob, conv.id, self.charlie.id)

        with pytest.raises(PermissionDenied, match="Only admins"):
            rename_group(self.bob, conv.id, "Hacked Group")

        with pytest.raises(PermissionDenied, match="Only admins"):
            change_member_role(
                self.bob, conv.id, self.charlie.id, Membership.ROLE_ADMIN
            )

    def test_last_admin_leave_rule_and_empty_group_deletion(self):
        conv = create_group(self.alice, "Devs", [self.bob.username])

        # Alice is the only admin. She cannot leave while Bob remains.
        with pytest.raises(ValidationError, match="The last admin cannot leave"):
            leave_group(self.alice, conv.id)

        # Alice promotes Bob to admin
        change_member_role(self.alice, conv.id, self.bob.id, Membership.ROLE_ADMIN)
        assert (
            Membership.objects.get(conversation=conv, user=self.bob).role
            == Membership.ROLE_ADMIN
        )

        # Now Alice can leave
        left, deleted = leave_group(self.alice, conv.id)
        assert left is True
        assert deleted is False
        assert not Membership.objects.filter(
            conversation=conv, user=self.alice
        ).exists()

        # Bob is now the last admin and last member. Bob leaves -> empty group is deleted in same tx.
        left, deleted = leave_group(self.bob, conv.id)
        assert left is True
        assert deleted is True
        assert not Conversation.objects.filter(id=conv.id).exists()

    def test_demote_last_admin_rejected(self):
        conv = create_group(self.alice, "Devs", [self.bob.username])
        with pytest.raises(ValidationError, match="Cannot demote the last admin"):
            change_member_role(
                self.alice, conv.id, self.alice.id, Membership.ROLE_MEMBER
            )

    def test_client_cannot_forge_is_system(self):
        conv = create_group(self.alice, "Devs", [self.bob.username])
        msg, is_new = send_message(
            self.alice, conv.id, "I am pretending to be system", "forge-1"
        )
        assert msg.is_system is False
        assert msg.system_data is None

    def test_group_ticks_math_over_three_members(self):
        # Alice, Bob, Charlie
        conv = create_group(
            self.alice, "Devs", [self.bob.username, self.charlie.username]
        )
        msg, _ = send_message(self.alice, conv.id, "Hello everyone", "msg-1")
        seq = msg.seq

        # Helper to compute group tick status for a sent message
        def derive_group_tick(sender_id, target_seq, memberships):
            other_m = [m for m in memberships if str(m.user_id) != str(sender_id)]
            if not other_m:
                return "sent"
            all_read = all(m.last_read_seq >= target_seq for m in other_m)
            if all_read:
                return "read"
            all_delivered = all(m.last_delivered_seq >= target_seq for m in other_m)
            if all_delivered:
                return "delivered"
            return "sent"

        members = list(conv.memberships.all())
        assert derive_group_tick(self.alice.id, seq, members) == "sent"

        # 1. Bob delivers
        update_membership_pointer(self.bob, conv.id, "delivered", seq)
        members = list(conv.memberships.all())
        # Bob delivered, but Charlie hasn't -> still sent
        assert derive_group_tick(self.alice.id, seq, members) == "sent"

        # 2. Charlie delivers -> now ALL other members delivered -> delivered!
        update_membership_pointer(self.charlie, conv.id, "delivered", seq)
        members = list(conv.memberships.all())
        assert derive_group_tick(self.alice.id, seq, members) == "delivered"

        # 3. Bob reads -> Charlie hasn't read yet -> still delivered
        update_membership_pointer(self.bob, conv.id, "read", seq)
        members = list(conv.memberships.all())
        assert derive_group_tick(self.alice.id, seq, members) == "delivered"

        # 4. Charlie reads -> ALL have read -> read!
        update_membership_pointer(self.charlie, conv.id, "read", seq)
        members = list(conv.memberships.all())
        assert derive_group_tick(self.alice.id, seq, members) == "read"

        # 5. Adding David later (Amendment 11): doesn't regress old ticks
        add_group_members(self.alice, conv.id, [self.david.username])
        members = list(conv.memberships.all())
        # For an old message (seq < david.joined_at_seq), david is already initialized to joined_at_seq >= seq!
        david_m = next(m for m in members if m.user_id == self.david.id)
        assert david_m.last_delivered_seq >= seq
        assert david_m.last_read_seq >= seq
        assert derive_group_tick(self.alice.id, seq, members) == "read"

    def test_group_monotonic_seq_concurrent_add_and_send(self):
        conv = create_group(self.alice, "Busy Devs", [self.bob.username])
        errors = []

        def worker_send(sender, i):
            try:
                send_message(
                    sender, conv.id, f"Msg {i}", f"client-{sender.username}-{i}"
                )
            except Exception as e:
                errors.append(e)
            finally:
                connection.close()

        def worker_add(user):
            try:
                add_group_members(self.alice, conv.id, [user.username])
            except Exception as e:
                errors.append(e)
            finally:
                connection.close()

        threads = []
        threads.append(threading.Thread(target=worker_send, args=(self.alice, 1)))
        threads.append(threading.Thread(target=worker_send, args=(self.bob, 2)))
        threads.append(threading.Thread(target=worker_add, args=(self.charlie,)))
        threads.append(threading.Thread(target=worker_send, args=(self.alice, 3)))
        threads.append(threading.Thread(target=worker_add, args=(self.david,)))

        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert not errors
        conv.refresh_from_db()

        # All messages must have strictly monotonic, gapless sequence numbers
        seqs = list(conv.messages.order_by("seq").values_list("seq", flat=True))
        assert seqs == list(range(1, len(seqs) + 1))

    def test_concurrent_remove_and_send(self):
        conv = create_group(
            self.alice, "Race Group", [self.bob.username, self.charlie.username]
        )

        results = {"send_msg": None, "send_error": None, "remove_error": None}

        def worker_send():
            from django.db import connection

            try:
                msg, _ = send_message(
                    self.bob, conv.id, "Bob racing send", "client-race-bob"
                )
                results["send_msg"] = msg
            except Exception as e:
                results["send_error"] = e
            finally:
                connection.close()

        def worker_remove():
            from django.db import connection

            try:
                remove_group_member(self.alice, conv.id, self.bob.id)
            except Exception as e:
                results["remove_error"] = e
            finally:
                connection.close()

        t_send = threading.Thread(target=worker_send)
        t_remove = threading.Thread(target=worker_remove)

        t_send.start()
        t_remove.start()
        t_send.join()
        t_remove.join()

        # Removal must always succeed without error
        assert results["remove_error"] is None

        # Bob must not be a member after the race
        assert not Membership.objects.filter(conversation=conv, user=self.bob).exists()

        # Exactly one of two consistent outcomes (documented in ADR 0024):
        if results["send_error"] is None:
            # Send won the race: Bob was a member at send time
            msg = results["send_msg"]
            assert msg is not None
            assert msg.seq is not None
            sys_msg = conv.messages.get(
                is_system=True, system_data__kind="member_removed"
            )
            assert msg.seq < sys_msg.seq
        else:
            # Removal won the race: send rejected as not-a-member
            assert isinstance(results["send_error"], PermissionDenied)
            assert not conv.messages.filter(client_id="client-race-bob").exists()

        # In both outcomes: strictly monotonic, gapless sequence numbers, no partial state
        conv.refresh_from_db()
        seqs = list(conv.messages.order_by("seq").values_list("seq", flat=True))
        assert seqs == list(range(1, len(seqs) + 1))
        assert conv.next_seq == len(seqs) + 1
