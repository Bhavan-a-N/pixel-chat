import json
import logging
import time
from typing import Any, Dict, List, Optional
from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from django.core.exceptions import PermissionDenied, ValidationError

from .services import ClientIdMismatchError, send_message

logger = logging.getLogger(__name__)

MAX_FRAME_SIZE = 65536  # 64 KB


class ChatConsumer(AsyncJsonWebsocketConsumer):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.send_timestamps: List[float] = []
        self.user = None
        self.user_group = None

    async def connect(self):
        self.user = self.scope.get("user")
        auth_error = self.scope.get("auth_error")

        # Accept connection first so client can observe close code 4401
        if (
            not self.user
            or self.user.is_anonymous
            or auth_error
            or not self.user.is_active
        ):
            await self.accept()
            await self.close(code=4401)
            return

        await self.accept()

        self.user_group = f"user_{self.user.id}"
        await self.channel_layer.group_add(self.user_group, self.channel_name)

    async def disconnect(self, close_code):
        if self.user_group and self.channel_layer:
            await self.channel_layer.group_discard(self.user_group, self.channel_name)

    async def receive(self, text_data=None, bytes_data=None):
        raw_data = (
            text_data
            if text_data is not None
            else (bytes_data.decode("utf-8") if bytes_data else "")
        )

        # 1. Size check
        if len(raw_data.encode("utf-8")) > MAX_FRAME_SIZE:
            await self.send_error(
                code=413,
                message="Payload Too Large: frame exceeds 64KB limit.",
                client_id=None,
            )
            return

        # 2. JSON parse
        try:
            data = json.loads(raw_data)
        except Exception:
            await self.send_error(
                code=400,
                message="Bad Request: malformed JSON frame.",
                client_id=None,
            )
            return

        if not isinstance(data, dict):
            await self.send_error(
                code=400,
                message="Bad Request: JSON payload must be an object.",
                client_id=None,
            )
            return

        client_id = data.get("client_id")

        # 3. Envelope validation: {v, type, payload, client_id}
        if data.get("v") != 1:
            await self.send_error(
                code=400,
                message="Bad Request: unsupported protocol version.",
                client_id=client_id,
            )
            return

        event_type = data.get("type")
        if event_type != "chat.send":
            await self.send_error(
                code=400,
                message=f"Bad Request: unsupported event type '{event_type}'.",
                client_id=client_id,
            )
            return

        payload = data.get("payload")
        if not isinstance(payload, dict):
            await self.send_error(
                code=400,
                message="Bad Request: payload must be an object.",
                client_id=client_id,
            )
            return

        # 4. Rate limit: 20 sends per 10 seconds per connection
        now = time.monotonic()
        self.send_timestamps = [t for t in self.send_timestamps if now - t < 10.0]
        if len(self.send_timestamps) >= 20:
            await self.send_error(
                code=429,
                message="Rate limit exceeded: maximum 20 sends per 10 seconds.",
                client_id=client_id,
            )
            return
        self.send_timestamps.append(now)

        conversation_id = payload.get("conversation_id")
        body = payload.get("body")

        if not conversation_id or not body:
            await self.send_error(
                code=400,
                message="Bad Request: conversation_id and body are required in payload.",
                client_id=client_id,
            )
            return

        if not client_id:
            await self.send_error(
                code=400,
                message="Bad Request: client_id is required.",
                client_id=None,
            )
            return

        # 5. Atomic send via database_sync_to_async
        try:
            message, is_new = await database_sync_to_async(send_message)(
                user=self.user,
                conversation_id=conversation_id,
                body=str(body),
                client_id=str(client_id),
            )
        except ClientIdMismatchError as e:
            await self.send_error(
                code=409,
                message=str(e),
                client_id=client_id,
            )
            return
        except PermissionDenied as e:
            await self.send_error(
                code=403,
                message=str(e),
                client_id=client_id,
            )
            return
        except ValidationError as e:
            msg = e.message if hasattr(e, "message") else str(e)
            await self.send_error(
                code=400,
                message=msg,
                client_id=client_id,
            )
            return
        except Exception as e:
            logger.exception("Error sending message: %s", e)
            await self.send_error(
                code=500,
                message="Internal server error.",
                client_id=client_id,
            )
            return

        # 6. Ack back to sender
        ack_payload = {
            "client_id": client_id,
            "message_id": str(message.id),
            "seq": message.seq,
            "status": "sent",
        }
        await self.send_json(
            {
                "v": 1,
                "type": "chat.ack",
                "client_id": client_id,
                "payload": ack_payload,
            }
        )

    async def chat_message(self, event: Dict[str, Any]):
        payload = event["payload"]
        await self.send_json(
            {
                "v": 1,
                "type": "chat.receive",
                "client_id": payload.get("client_id"),
                "payload": payload,
            }
        )

    async def send_error(
        self,
        code: int,
        message: str,
        client_id: Optional[str] = None,
    ):
        await self.send_json(
            {
                "v": 1,
                "type": "error",
                "client_id": client_id,
                "payload": {
                    "code": code,
                    "message": message,
                },
            }
        )
