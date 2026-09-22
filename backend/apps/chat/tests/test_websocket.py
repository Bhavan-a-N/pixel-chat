import os
from datetime import timedelta
from unittest.mock import patch
from channels.testing import WebsocketCommunicator
from django.contrib.auth import get_user_model
from django.utils import timezone
import pytest
from rest_framework_simplejwt.tokens import AccessToken

os.environ["DJANGO_ALLOW_ASYNC_UNSAFE"] = "true"

from channels.db import database_sync_to_async
from apps.chat.models import Message
from apps.chat.services import get_or_create_dm, send_message, update_membership_pointer
from config.asgi import application

User = get_user_model()


def get_token_for_user(user, expired=False) -> str:
    token = AccessToken.for_user(user)
    if expired:
        # Set token expiration in the past
        token.set_exp(from_time=timezone.now() - timedelta(days=1))
    return str(token)


@pytest.mark.django_db(transaction=True)
class TestWebSocketAuth:
    @pytest.fixture(autouse=True)
    def setup_users(self):
        self.user = User.objects.create_user(
            email="alice@example.com",
            username="alice",
            password="Password123!",
        )
        self.inactive_user = User.objects.create_user(
            email="inactive@example.com",
            username="inactive",
            password="Password123!",
            is_active=False,
        )

    async def test_connect_without_token_closes_with_4401(self):
        communicator = WebsocketCommunicator(application, "/ws/chat/")
        connected, _ = await communicator.connect()
        assert connected is True
        response = await communicator.receive_output()
        assert response["type"] == "websocket.close"
        assert response["code"] == 4401
        await communicator.disconnect()

    async def test_connect_with_bad_token_closes_with_4401(self):
        communicator = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", b"Bearer invalid.jwt.token")],
        )
        connected, _ = await communicator.connect()
        assert connected is True
        response = await communicator.receive_output()
        assert response["type"] == "websocket.close"
        assert response["code"] == 4401
        await communicator.disconnect()

    async def test_connect_with_expired_token_closes_with_4401(self):
        expired_token = get_token_for_user(self.user, expired=True)
        communicator = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {expired_token}".encode("utf-8"))],
        )
        connected, _ = await communicator.connect()
        assert connected is True
        response = await communicator.receive_output()
        assert response["type"] == "websocket.close"
        assert response["code"] == 4401
        await communicator.disconnect()

    async def test_connect_with_inactive_user_closes_with_4401(self):
        token = get_token_for_user(self.inactive_user)
        communicator = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {token}".encode("utf-8"))],
        )
        connected, _ = await communicator.connect()
        assert connected is True
        response = await communicator.receive_output()
        assert response["type"] == "websocket.close"
        assert response["code"] == 4401
        await communicator.disconnect()

    async def test_connect_with_valid_token_succeeds(self):
        token = get_token_for_user(self.user)
        communicator = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {token}".encode("utf-8"))],
        )
        connected, _ = await communicator.connect()
        assert connected is True
        # Connection should stay open without immediate close
        await communicator.disconnect()


@pytest.mark.django_db(transaction=True)
class TestWebSocketMessaging:
    @pytest.fixture(autouse=True)
    def setup_data(self):
        self.user1 = User.objects.create_user(
            email="u1@example.com",
            username="u1",
            password="Password123!",
        )
        self.user2 = User.objects.create_user(
            email="u2@example.com",
            username="u2",
            password="Password123!",
        )
        self.user3 = User.objects.create_user(
            email="u3@example.com",
            username="u3",
            password="Password123!",
        )

        self.token1 = get_token_for_user(self.user1)
        self.token2 = get_token_for_user(self.user2)
        self.token3 = get_token_for_user(self.user3)

    async def create_authenticated_communicator(
        self, token: str
    ) -> WebsocketCommunicator:
        comm = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {token}".encode("utf-8"))],
        )
        connected, _ = await comm.connect()
        assert connected is True
        return comm

    async def test_send_ack_and_broadcast_receive(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        comm1 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        comm2 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token2}".encode("utf-8"))],
        )

        assert (await comm1.connect())[0] is True
        assert (await comm2.connect())[0] is True

        # User 1 sends message
        send_frame = {
            "v": 1,
            "type": "chat.send",
            "client_id": "cid-100",
            "payload": {
                "conversation_id": str(conv.id),
                "body": "Hello Bob via WebSocket!",
            },
        }
        await comm1.send_json_to(send_frame)

        # 1. Sender receives chat.ack with status "sent"
        ack_res = await comm1.receive_json_from()
        assert ack_res["v"] == 1
        assert ack_res["type"] == "chat.ack"
        assert ack_res["client_id"] == "cid-100"
        assert ack_res["payload"]["seq"] == 1
        assert ack_res["payload"]["status"] == "sent"

        # 2. Recipient receives chat.receive broadcast
        recv_res = await comm2.receive_json_from()
        assert recv_res["v"] == 1
        assert recv_res["type"] == "chat.receive"
        assert recv_res["payload"]["seq"] == 1
        assert recv_res["payload"]["body"] == "Hello Bob via WebSocket!"
        assert recv_res["payload"]["conversation_id"] == str(conv.id)

        # 3. Message persisted in DB
        msg = Message.objects.get(conversation=conv, seq=1)
        assert msg.body == "Hello Bob via WebSocket!"

        await comm1.disconnect()
        await comm2.disconnect()

    async def test_duplicate_client_id_returns_same_message_and_no_second_broadcast(
        self,
    ):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        comm1 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        comm2 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token2}".encode("utf-8"))],
        )

        await comm1.connect()
        await comm2.connect()

        send_frame = {
            "v": 1,
            "type": "chat.send",
            "client_id": "cid-duplicate",
            "payload": {
                "conversation_id": str(conv.id),
                "body": "Original Body",
            },
        }

        # Send first time
        await comm1.send_json_to(send_frame)
        ack1 = await comm1.receive_json_from()
        assert ack1["payload"]["status"] == "sent"
        # Sender also gets broadcast as group member
        recv_sender = await comm1.receive_json_from()
        assert recv_sender["type"] == "chat.receive"
        recv1 = await comm2.receive_json_from()
        assert recv1["payload"]["seq"] == 1

        # Resend with exact same client_id: must ack status "sent", never "delivered"
        await comm1.send_json_to(send_frame)
        ack2 = await comm1.receive_json_from()
        assert ack2["payload"]["status"] == "sent"
        assert ack2["payload"]["seq"] == 1
        assert ack2["payload"]["message_id"] == ack1["payload"]["message_id"]

        # Assert User 1 and User 2 receive nothing further (no duplicate broadcast)
        assert await comm1.receive_nothing() is True
        assert await comm2.receive_nothing() is True

        # Database still only has 1 message
        assert Message.objects.filter(conversation=conv).count() == 1

        await comm1.disconnect()
        await comm2.disconnect()

    async def test_non_member_receives_no_broadcasts(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        comm1 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        comm2 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token2}".encode("utf-8"))],
        )
        comm3_non_member = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token3}".encode("utf-8"))],
        )

        await comm1.connect()
        await comm2.connect()
        await comm3_non_member.connect()

        # User 1 sends message to conversation (members: user1, user2)
        await comm1.send_json_to(
            {
                "v": 1,
                "type": "chat.send",
                "client_id": "nm-test-1",
                "payload": {
                    "conversation_id": str(conv.id),
                    "body": "Private message between U1 and U2",
                },
            }
        )

        # Member 1 gets ack
        ack = await comm1.receive_json_from()
        assert ack["payload"]["status"] == "sent"

        # Member 2 gets broadcast
        recv = await comm2.receive_json_from()
        assert recv["payload"]["body"] == "Private message between U1 and U2"

        # Non-member User 3 receives NOTHING
        assert await comm3_non_member.receive_nothing() is True

        await comm1.disconnect()
        await comm2.disconnect()
        await comm3_non_member.disconnect()

    async def test_cross_conversation_client_id_rejected_via_websocket(self):
        conv1, _ = get_or_create_dm(self.user1, self.user2)
        conv2, _ = get_or_create_dm(self.user1, self.user3)

        # Pre-populate message in conv1 with client_id
        send_message(self.user1, conv1.id, "Msg in Conv1", "cross-cid-1")

        comm1 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        await comm1.connect()

        # Try to use same client_id in conv2
        await comm1.send_json_to(
            {
                "v": 1,
                "type": "chat.send",
                "client_id": "cross-cid-1",
                "payload": {
                    "conversation_id": str(conv2.id),
                    "body": "Msg in Conv2 with duplicate client_id",
                },
            }
        )

        err = await comm1.receive_json_from()
        assert err["type"] == "error"
        assert err["payload"]["code"] == 409
        assert "cross-cid-1" in err["payload"]["message"]

        await comm1.disconnect()

    async def test_new_conversation_created_after_connect_works(self):
        # Users connect before any conversation exists between them
        comm1 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        comm2 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token2}".encode("utf-8"))],
        )

        await comm1.connect()
        await comm2.connect()

        # Conversation created while both sockets are already connected
        conv, _ = get_or_create_dm(self.user1, self.user2)

        # Send message
        await comm1.send_json_to(
            {
                "v": 1,
                "type": "chat.send",
                "client_id": "post-connect-1",
                "payload": {
                    "conversation_id": str(conv.id),
                    "body": "Message in new conversation",
                },
            }
        )

        await comm1.receive_json_from()  # ack
        recv = await comm2.receive_json_from()
        assert recv["payload"]["body"] == "Message in new conversation"

        await comm1.disconnect()
        await comm2.disconnect()

    async def test_failing_group_send_does_not_crash_consumer_and_sender_still_acks(
        self,
    ):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        comm1 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        await comm1.connect()

        # Simulate failing channel layer group_send
        with patch("channels_redis.core.RedisChannelLayer.group_send") as mock_send:
            mock_send.side_effect = Exception("Simulated Redis Connection Drop")

            await comm1.send_json_to(
                {
                    "v": 1,
                    "type": "chat.send",
                    "client_id": "fail-group-send",
                    "payload": {
                        "conversation_id": str(conv.id),
                        "body": "Persisted even if broadcast drops",
                    },
                }
            )

            # Sender must still receive its ack with status "sent"!
            ack = await comm1.receive_json_from()
            assert ack["type"] == "chat.ack"
            assert ack["payload"]["client_id"] == "fail-group-send"
            assert ack["payload"]["status"] == "sent"

            # Message is safely persisted
            assert Message.objects.filter(client_id="fail-group-send").exists()

        await comm1.disconnect()

    async def test_non_member_cannot_send_and_receives_error_event(self):
        conv, _ = get_or_create_dm(self.user1, self.user2)

        comm3 = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token3}".encode("utf-8"))],
        )
        await comm3.connect()

        await comm3.send_json_to(
            {
                "v": 1,
                "type": "chat.send",
                "client_id": "intruder-send",
                "payload": {
                    "conversation_id": str(conv.id),
                    "body": "Trying to send to private chat",
                },
            }
        )

        err = await comm3.receive_json_from()
        assert err["type"] == "error"
        assert err["payload"]["code"] == 403

        # Socket remains connected
        assert await comm3.receive_nothing() is True
        await comm3.disconnect()

    async def test_malformed_frames_and_rate_limiting(self):
        comm = WebsocketCommunicator(
            application,
            "/ws/chat/",
            headers=[(b"authorization", f"Bearer {self.token1}".encode("utf-8"))],
        )
        await comm.connect()

        # 1. Malformed JSON
        await comm.send_to(text_data="not-valid-json{")
        err1 = await comm.receive_json_from()
        assert err1["type"] == "error"
        assert err1["payload"]["code"] == 400

        # 2. Unsupported protocol version
        await comm.send_json_to(
            {"v": 2, "type": "chat.send", "client_id": "c1", "payload": {}}
        )
        err2 = await comm.receive_json_from()
        assert err2["type"] == "error"
        assert err2["payload"]["code"] == 400

        # 3. Unknown event type
        await comm.send_json_to(
            {"v": 1, "type": "unknown.type", "client_id": "c1", "payload": {}}
        )
        err3 = await comm.receive_json_from()
        assert err3["type"] == "error"
        assert err3["payload"]["code"] == 400

        # 4. Oversized frame (> 64KB)
        oversize = "x" * (65536 + 10)
        await comm.send_to(text_data=oversize)
        err4 = await comm.receive_json_from()
        assert err4["type"] == "error"
        assert err4["payload"]["code"] == 413

        # 5. Rate limiting: 20 sends per 10s
        conv, _ = get_or_create_dm(self.user1, self.user2)
        for i in range(20):
            await comm.send_json_to(
                {
                    "v": 1,
                    "type": "chat.send",
                    "client_id": f"rate-{i}",
                    "payload": {"conversation_id": str(conv.id), "body": f"Burst {i}"},
                }
            )
            await comm.receive_json_from()  # consume ack
            await comm.receive_json_from()  # consume broadcast

        # 21st send should trigger 429
        await comm.send_json_to(
            {
                "v": 1,
                "type": "chat.send",
                "client_id": "rate-overflow",
                "payload": {"conversation_id": str(conv.id), "body": "Over limit"},
            }
        )
        err_rate = await comm.receive_json_from()
        assert err_rate["type"] == "error"
        assert err_rate["payload"]["code"] == 429

        # Connection stays open
        await comm.disconnect()

    async def test_delivered_and_read_status_ack_and_broadcast(self):
        token1 = get_token_for_user(self.user1)
        token2 = get_token_for_user(self.user2)

        comm1 = await self.create_authenticated_communicator(token1)
        comm2 = await self.create_authenticated_communicator(token2)

        conv, _ = get_or_create_dm(self.user1, self.user2)

        # Alice sends message (seq 1)
        await comm1.send_json_to(
            {
                "v": 1,
                "type": "chat.send",
                "client_id": "alice-msg-1",
                "payload": {"conversation_id": str(conv.id), "body": "Hello Bob"},
            }
        )
        await comm1.receive_json_from()  # consume alice ack
        await comm1.receive_json_from()  # consume alice broadcast

        # Bob receives message
        bob_rcv = await comm2.receive_json_from()
        assert bob_rcv["type"] == "chat.receive"
        assert bob_rcv["payload"]["seq"] == 1

        # Bob sends chat.delivered for seq 1
        await comm2.send_json_to(
            {
                "v": 1,
                "type": "chat.delivered",
                "client_id": "bob-del-1",
                "payload": {"conversation_id": str(conv.id), "seq": 1},
            }
        )

        # Both Alice and Bob (including other devices of Bob) get chat.status broadcast
        alice_status = await comm1.receive_json_from()
        assert alice_status["type"] == "chat.status"
        assert alice_status["payload"]["conversation_id"] == str(conv.id)
        assert alice_status["payload"]["user_id"] == str(self.user2.id)
        assert alice_status["payload"]["delivered_seq"] == 1
        assert alice_status["payload"]["read_seq"] == 0

        bob_status = await comm2.receive_json_from()
        assert bob_status["type"] == "chat.status"
        assert bob_status["payload"]["delivered_seq"] == 1

        # Stale ack: Bob sends chat.delivered again for seq 1 -> zero rows updated, NO broadcast
        await comm2.send_json_to(
            {
                "v": 1,
                "type": "chat.delivered",
                "client_id": "bob-del-repeat",
                "payload": {"conversation_id": str(conv.id), "seq": 1},
            }
        )
        # Verify no broadcast received by Alice
        assert await comm1.receive_nothing(timeout=0.2) is True

        # Bob sends chat.read for seq 1 -> delivered raised to at least 1, read becomes 1
        await comm2.send_json_to(
            {
                "v": 1,
                "type": "chat.read",
                "client_id": "bob-read-1",
                "payload": {"conversation_id": str(conv.id), "seq": 1},
            }
        )

        alice_read_status = await comm1.receive_json_from()
        assert alice_read_status["type"] == "chat.status"
        assert alice_read_status["payload"]["delivered_seq"] == 1
        assert alice_read_status["payload"]["read_seq"] == 1

        await comm1.disconnect()
        await comm2.disconnect()

    async def test_status_ack_seq_beyond_max_and_non_member_returns_error(self):
        conv, _ = await database_sync_to_async(get_or_create_dm)(self.user1, self.user2)
        await database_sync_to_async(send_message)(
            self.user1, conv.id, "Seed message", "seed-1"
        )

        token1 = get_token_for_user(self.user1)
        token_charlie = get_token_for_user(self.user3)

        comm1 = await self.create_authenticated_communicator(token1)
        comm_charlie = await self.create_authenticated_communicator(token_charlie)

        # 1. Seq beyond max (conv next_seq is 2, max is 1)
        await comm1.send_json_to(
            {
                "v": 1,
                "type": "chat.delivered",
                "client_id": "err-beyond",
                "payload": {"conversation_id": str(conv.id), "seq": 5},
            }
        )
        err = await comm1.receive_json_from()
        assert err["type"] == "error"
        assert err["payload"]["code"] == 400

        # 2. Non-member (Charlie)
        await comm_charlie.send_json_to(
            {
                "v": 1,
                "type": "chat.delivered",
                "client_id": "err-nonmember",
                "payload": {"conversation_id": str(conv.id), "seq": 1},
            }
        )
        err2 = await comm_charlie.receive_json_from()
        assert err2["type"] == "error"
        assert err2["payload"]["code"] == 403

        await comm1.disconnect()
        await comm_charlie.disconnect()

    async def test_status_ack_rate_limiting_keeps_connection_open(self):
        conv, _ = await database_sync_to_async(get_or_create_dm)(self.user1, self.user2)
        await database_sync_to_async(send_message)(
            self.user1, conv.id, "Seed message", "seed-rl"
        )
        # Pre-set pointer to 1 so the 60 allowed frames are stale and produce 0 output frames
        await database_sync_to_async(update_membership_pointer)(
            self.user1, conv.id, "delivered", 1
        )

        token = get_token_for_user(self.user1)
        comm = await self.create_authenticated_communicator(token)

        # Send 60 status updates quickly (allowed, no broadcast generated because stale)
        for i in range(60):
            await comm.send_json_to(
                {
                    "v": 1,
                    "type": "chat.delivered",
                    "client_id": f"stat-{i}",
                    "payload": {"conversation_id": str(conv.id), "seq": 1},
                }
            )

        # 61st status update exceeds 60/10s rate limit
        await comm.send_json_to(
            {
                "v": 1,
                "type": "chat.delivered",
                "client_id": "stat-over",
                "payload": {"conversation_id": str(conv.id), "seq": 1},
            }
        )
        err = await comm.receive_json_from(timeout=10)
        assert err["type"] == "error"
        assert err["payload"]["code"] == 429

        # Socket still open and functional
        await comm.disconnect()
