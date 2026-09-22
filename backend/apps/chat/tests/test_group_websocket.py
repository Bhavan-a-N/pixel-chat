import os
from channels.db import database_sync_to_async
from channels.testing import WebsocketCommunicator
from django.contrib.auth import get_user_model
import pytest
from rest_framework_simplejwt.tokens import AccessToken

os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"

from apps.chat.models import Message
from apps.chat.services import (
    add_group_members,
    create_group,
    remove_group_member,
)
from config.asgi import application

User = get_user_model()


def get_token_for_user(user) -> str:
    return str(AccessToken.for_user(user))


@pytest.mark.django_db(transaction=True)
class TestGroupWebSocket:
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

        self.token_alice = get_token_for_user(self.alice)
        self.token_bob = get_token_for_user(self.bob)
        self.token_charlie = get_token_for_user(self.charlie)
        self.token_david = get_token_for_user(self.david)

    async def _create_communicator(self, token: str) -> WebsocketCommunicator:
        comm = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {token}".encode("utf-8"))],
        )
        connected, _ = await comm.connect()
        assert connected is True
        return comm

    async def test_group_send_and_broadcast_all_members(self):
        conv = await database_sync_to_async(create_group)(
            self.alice, "Alpha Squad", [self.bob.id, self.charlie.id]
        )

        comm_alice = await self._create_communicator(self.token_alice)
        comm_bob = await self._create_communicator(self.token_bob)
        comm_charlie = await self._create_communicator(self.token_charlie)

        send_frame = {
            "v": 1,
            "type": "chat.send",
            "client_id": "c-group-1",
            "payload": {
                "conversation_id": str(conv.id),
                "body": "Hello Squad!",
            },
        }
        await comm_alice.send_json_to(send_frame)

        # 1. Alice gets ack
        ack = await comm_alice.receive_json_from()
        assert ack["type"] == "chat.ack"
        assert ack["client_id"] == "c-group-1"
        assert ack["payload"]["seq"] == 2  # Seq 1 was group_created system message

        # 2. Bob gets broadcast
        recv_bob = await comm_bob.receive_json_from()
        assert recv_bob["type"] == "chat.receive"
        assert recv_bob["payload"]["seq"] == 2
        assert recv_bob["payload"]["body"] == "Hello Squad!"
        assert recv_bob["payload"]["sender_display_name"] == "Alice A"
        assert recv_bob["payload"]["sender_avatar_seed"] == "alice-seed"

        # 3. Charlie gets broadcast
        recv_charlie = await comm_charlie.receive_json_from()
        assert recv_charlie["type"] == "chat.receive"
        assert recv_charlie["payload"]["seq"] == 2
        assert recv_charlie["payload"]["sender_display_name"] == "Alice A"

        await comm_alice.disconnect()
        await comm_bob.disconnect()
        await comm_charlie.disconnect()

    async def test_client_cannot_forge_is_system(self):
        conv = await database_sync_to_async(create_group)(
            self.alice, "Security Group", [self.bob.id]
        )

        comm_alice = await self._create_communicator(self.token_alice)
        comm_bob = await self._create_communicator(self.token_bob)

        # Attempt to inject is_system=True and forged system_data
        send_frame = {
            "v": 1,
            "type": "chat.send",
            "client_id": "c-forge-1",
            "payload": {
                "conversation_id": str(conv.id),
                "body": "Forged system message",
                "is_system": True,
                "system_data": {"kind": "admin_granted"},
            },
        }
        await comm_alice.send_json_to(send_frame)

        ack = await comm_alice.receive_json_from()
        assert ack["type"] == "chat.ack"
        seq = ack["payload"]["seq"]

        # Recipient receives broadcast
        recv_bob = await comm_bob.receive_json_from()
        assert recv_bob["type"] == "chat.receive"
        assert recv_bob["payload"]["is_system"] is False
        assert recv_bob["payload"]["system_data"] is None

        # DB has is_system=False and system_data=None
        msg = await database_sync_to_async(Message.objects.get)(
            conversation=conv, seq=seq
        )
        assert msg.is_system is False
        assert msg.system_data is None

        await comm_alice.disconnect()
        await comm_bob.disconnect()

    async def test_group_typing_broadcast_to_current_members_only(self):
        conv = await database_sync_to_async(create_group)(
            self.alice, "Typing Test", [self.bob.id, self.charlie.id]
        )

        comm_alice = await self._create_communicator(self.token_alice)
        comm_bob = await self._create_communicator(self.token_bob)
        comm_charlie = await self._create_communicator(self.token_charlie)
        comm_david = await self._create_communicator(self.token_david)

        # Alice types
        typing_frame = {
            "v": 1,
            "type": "chat.typing",
            "payload": {
                "conversation_id": str(conv.id),
                "is_typing": True,
            },
        }
        await comm_alice.send_json_to(typing_frame)

        # Bob receives typing event
        recv_bob = await comm_bob.receive_json_from()
        assert recv_bob["type"] == "chat.typing"
        assert recv_bob["payload"]["conversation_id"] == str(conv.id)
        assert recv_bob["payload"]["user_id"] == str(self.alice.id)
        assert recv_bob["payload"]["username"] == "alice"
        assert recv_bob["payload"]["display_name"] == "Alice A"
        assert recv_bob["payload"]["is_typing"] is True

        # Charlie receives typing event
        recv_charlie = await comm_charlie.receive_json_from()
        assert recv_charlie["type"] == "chat.typing"
        assert recv_charlie["payload"]["user_id"] == str(self.alice.id)

        # David (non-member) does NOT receive anything
        assert await comm_david.receive_nothing() is True

        await comm_alice.disconnect()
        await comm_bob.disconnect()
        await comm_charlie.disconnect()
        await comm_david.disconnect()

    async def test_membership_added_delivered_to_open_sockets(self):
        conv = await database_sync_to_async(create_group)(
            self.alice, "Growing Group", [self.bob.id]
        )

        comm_alice = await self._create_communicator(self.token_alice)
        comm_bob = await self._create_communicator(self.token_bob)
        comm_charlie = await self._create_communicator(self.token_charlie)

        # Admin Alice adds Charlie via service
        await database_sync_to_async(add_group_members)(
            self.alice, conv.id, [self.charlie.id]
        )

        # Bob receives system message chat.receive and membership.added
        events_bob = [
            await comm_bob.receive_json_from(),
            await comm_bob.receive_json_from(),
        ]
        event_types_bob = {e["type"] for e in events_bob}
        assert "chat.message" in event_types_bob or "chat.receive" in event_types_bob
        assert "membership.added" in event_types_bob

        # Charlie receives membership.added
        events_charlie = [
            await comm_charlie.receive_json_from(),
            await comm_charlie.receive_json_from(),
        ]
        event_types_charlie = {e["type"] for e in events_charlie}
        assert "membership.added" in event_types_charlie

        await comm_alice.disconnect()
        await comm_bob.disconnect()
        await comm_charlie.disconnect()

    async def test_removed_member_receives_removed_event_and_no_further_events(self):
        conv = await database_sync_to_async(create_group)(
            self.alice, "Trimming Group", [self.bob.id, self.charlie.id]
        )

        comm_alice = await self._create_communicator(self.token_alice)
        comm_bob = await self._create_communicator(self.token_bob)
        comm_charlie = await self._create_communicator(self.token_charlie)

        # Admin Alice removes Charlie
        await database_sync_to_async(remove_group_member)(
            self.alice, conv.id, self.charlie.id
        )

        # Charlie receives membership.removed
        recv_charlie = await comm_charlie.receive_json_from()
        assert recv_charlie["type"] == "membership.removed"
        assert recv_charlie["payload"]["conversation_id"] == str(conv.id)
        assert recv_charlie["payload"]["user_id"] == str(self.charlie.id)

        # Alice sends another message
        send_frame = {
            "v": 1,
            "type": "chat.send",
            "client_id": "c-after-remove-1",
            "payload": {
                "conversation_id": str(conv.id),
                "body": "Charlie is gone",
            },
        }
        await comm_alice.send_json_to(send_frame)

        # Drain events until we find chat.ack for our send (Alice may also receive
        # a membership.removed fanout for Charlie before the ack arrives).
        ack_found = False
        for _ in range(10):
            event = await comm_alice.receive_json_from(timeout=5)
            if (
                event.get("type") == "chat.ack"
                and event.get("client_id") == "c-after-remove-1"
            ):
                ack_found = True
                break
        assert ack_found is True

        # Bob gets message; drain until we find it (Bob first sees membership.removed).
        msg_found_for_bob = False
        for _ in range(10):
            event = await comm_bob.receive_json_from(timeout=5)
            if (
                event["type"] == "chat.receive"
                and event["payload"].get("body") == "Charlie is gone"
            ):
                msg_found_for_bob = True
                break
        assert msg_found_for_bob is True

        # Charlie receives NOTHING more
        assert await comm_charlie.receive_nothing() is True

        await comm_alice.disconnect()
        await comm_bob.disconnect()
        await comm_charlie.disconnect()

    async def test_send_after_removal_rejected_on_open_socket(self):
        conv = await database_sync_to_async(create_group)(
            self.alice, "Exclusion Group", [self.bob.id]
        )

        comm_alice = await self._create_communicator(self.token_alice)
        comm_bob = await self._create_communicator(self.token_bob)

        # Alice removes Bob
        await database_sync_to_async(remove_group_member)(
            self.alice, conv.id, self.bob.id
        )

        # Bob receives membership.removed
        await comm_bob.receive_json_from()

        # Bob tries to send a message on his still-open socket
        send_frame = {
            "v": 1,
            "type": "chat.send",
            "client_id": "c-illegal-send",
            "payload": {
                "conversation_id": str(conv.id),
                "body": "Let me back in!",
            },
        }
        await comm_bob.send_json_to(send_frame)

        # Bob receives error event
        err_res = await comm_bob.receive_json_from()
        assert err_res["type"] == "chat.error" or err_res["type"] == "error"
        assert err_res["client_id"] == "c-illegal-send"

        # Verify no message persisted in conversation
        exists = await database_sync_to_async(
            Message.objects.filter(conversation=conv, body="Let me back in!").exists
        )()
        assert not exists

        await comm_alice.disconnect()
        await comm_bob.disconnect()
