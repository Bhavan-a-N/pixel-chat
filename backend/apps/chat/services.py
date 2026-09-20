import logging
from typing import Any, Tuple
from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction

from .models import Conversation, Membership, Message

logger = logging.getLogger(__name__)


class ClientIdMismatchError(Exception):
    pass


def send_message(
    user: Any,
    conversation_id: Any,
    body: str,
    client_id: str,
) -> Tuple[Message, bool]:
    cleaned_body = body.strip() if body else ""
    if not cleaned_body:
        raise ValidationError("Message body cannot be empty or whitespace only.")
    if len(cleaned_body) > 4000:
        raise ValidationError("Message body exceeds 4000 character limit.")

    with transaction.atomic():
        # Verify sender membership
        membership_exists = Membership.objects.filter(
            conversation_id=conversation_id,
            user=user,
        ).exists()
        if not membership_exists:
            raise PermissionDenied("You are not a member of this conversation.")

        # Check existing (sender, client_id)
        existing_msg = Message.objects.filter(
            sender=user,
            client_id=client_id,
        ).first()

        if existing_msg is not None:
            if str(existing_msg.conversation_id) != str(conversation_id):
                raise ClientIdMismatchError(
                    f"client_id '{client_id}' already used in a different conversation."
                )
            # Idempotent return: no seq consumed, no broadcast
            return existing_msg, False

        # Lock conversation for seq assignment
        conversation = Conversation.objects.select_for_update().get(id=conversation_id)

        seq = conversation.next_seq
        conversation.next_seq += 1
        conversation.save(update_fields=["next_seq", "updated_at"])

        message = Message.objects.create(
            conversation=conversation,
            sender=user,
            seq=seq,
            body=cleaned_body,
            client_id=client_id,
        )

        member_ids = list(
            Membership.objects.filter(conversation=conversation).values_list(
                "user_id", flat=True
            )
        )

        message_payload = {
            "id": str(message.id),
            "conversation_id": str(conversation.id),
            "sender_id": str(user.id),
            "seq": message.seq,
            "body": message.body,
            "client_id": message.client_id,
            "created_at": message.created_at.isoformat(),
        }

        def on_commit_broadcast() -> None:
            channel_layer = get_channel_layer()
            if channel_layer is None:
                return

            event = {
                "type": "chat.message",
                "payload": message_payload,
            }

            for member_id in member_ids:
                try:
                    async_to_sync(channel_layer.group_send)(
                        f"user_{member_id}",
                        event,
                    )
                except Exception as e:
                    logger.warning(
                        "Failed to broadcast message to user_%s group: %s",
                        member_id,
                        e,
                        exc_info=True,
                    )

        transaction.on_commit(on_commit_broadcast)

        return message, True


def get_or_create_dm(user1: Any, user2: Any) -> Tuple[Conversation, bool]:
    if user1.id == user2.id:
        raise ValidationError("Cannot create a DM with yourself.")

    sorted_ids = sorted([str(user1.id), str(user2.id)])
    dm_key = f"{sorted_ids[0]}:{sorted_ids[1]}"

    with transaction.atomic():
        conv, created = Conversation.objects.get_or_create(
            dm_key=dm_key,
            defaults={"type": Conversation.TYPE_DM},
        )
        if created:
            Membership.objects.create(
                conversation=conv,
                user=user1,
                role=Membership.ROLE_MEMBER,
            )
            Membership.objects.create(
                conversation=conv,
                user=user2,
                role=Membership.ROLE_MEMBER,
            )
        return conv, created
