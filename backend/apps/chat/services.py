import asyncio
import logging
import uuid
from typing import Any, Dict, List, Optional, Tuple
from asgiref.sync import async_to_sync
from channels.layers import get_channel_layer
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.db.models import F
from django.db.models.functions import Greatest

from .models import Conversation, Membership, Message

logger = logging.getLogger(__name__)
User = get_user_model()


class ClientIdMismatchError(Exception):
    pass


class NotAMemberError(Exception):
    pass


class InvalidSeqError(Exception):
    pass


def _broadcast_to_users(
    user_ids: List[Any], event_type: str, payload: Dict[str, Any]
) -> None:
    def on_commit_send():
        channel_layer = get_channel_layer()
        if channel_layer is None:
            return
        event = {
            "type": event_type,
            "payload": payload,
        }
        for uid in user_ids:
            try:
                try:
                    loop = asyncio.get_running_loop()
                except RuntimeError:
                    loop = None

                if loop and loop.is_running():
                    loop.create_task(channel_layer.group_send(f"user_{uid}", event))
                else:
                    async_to_sync(channel_layer.group_send)(
                        f"user_{uid}",
                        event,
                    )
            except Exception as e:
                logger.warning(
                    "Failed to broadcast %s to user_%s group: %s",
                    event_type,
                    uid,
                    e,
                    exc_info=True,
                )

    transaction.on_commit(on_commit_send)


def _create_system_message(
    conversation: Conversation,
    actor: Any,
    kind: str,
    text: str,
    target_ids: Optional[List[str]] = None,
) -> Message:
    seq = conversation.next_seq
    conversation.next_seq += 1
    conversation.save(update_fields=["next_seq", "updated_at"])

    client_id = f"sys-{uuid.uuid4()}"
    msg = Message.objects.create(
        conversation=conversation,
        sender=actor,
        seq=seq,
        body=text,
        client_id=client_id,
        is_system=True,
        system_data={
            "kind": kind,
            "actor_id": str(actor.id),
            "target_ids": [str(tid) for tid in (target_ids or [])],
        },
    )
    return msg


def _make_message_payload(message: Message, sender: Any) -> Dict[str, Any]:
    return {
        "id": str(message.id),
        "conversation_id": str(message.conversation_id),
        "sender_id": str(message.sender_id),
        "sender_display_name": getattr(sender, "display_name", "") or sender.username,
        "sender_avatar_seed": getattr(sender, "avatar_seed", ""),
        "seq": message.seq,
        "body": message.body,
        "client_id": message.client_id,
        "is_system": message.is_system,
        "system_data": message.system_data,
        "created_at": message.created_at.isoformat(),
    }


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
        # Lock conversation for seq assignment and serialization
        try:
            conversation = Conversation.objects.select_for_update().get(
                id=conversation_id
            )
        except Conversation.DoesNotExist:
            raise PermissionDenied("You are not a member of this conversation.")

        # Verify sender membership under conversation lock
        membership_exists = Membership.objects.filter(
            conversation=conversation,
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

        seq = conversation.next_seq
        conversation.next_seq += 1
        conversation.save(update_fields=["next_seq", "updated_at"])

        # client messages can NEVER set is_system=True
        message = Message.objects.create(
            conversation=conversation,
            sender=user,
            seq=seq,
            body=cleaned_body,
            client_id=client_id,
            is_system=False,
            system_data=None,
        )

        member_ids = list(
            Membership.objects.filter(conversation=conversation).values_list(
                "user_id", flat=True
            )
        )

        message_payload = _make_message_payload(message, user)
        _broadcast_to_users(member_ids, "chat.message", message_payload)

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
                joined_at_seq=0,
            )
            Membership.objects.create(
                conversation=conv,
                user=user2,
                role=Membership.ROLE_MEMBER,
                joined_at_seq=0,
            )
        return conv, created


def create_group(
    creator: Any,
    name: str,
    member_identifiers: List[Any],
) -> Conversation:
    cleaned_name = name.strip() if name else ""
    if not cleaned_name:
        raise ValidationError("Group name cannot be empty.")
    if len(cleaned_name) > 50:
        raise ValidationError("Group name exceeds 50 characters.")

    # Resolve member identifiers
    resolved_users: Dict[Any, Any] = {}
    resolved_users[creator.id] = creator

    for ident in member_identifiers:
        ident_str = str(ident).strip()
        if not ident_str:
            continue
        # Check by id (UUID) or username
        u = None
        try:
            val_uuid = uuid.UUID(ident_str)
            u = User.objects.filter(id=val_uuid).first()
        except ValueError:
            pass
        if u is None:
            u = User.objects.filter(username__iexact=ident_str).first()
        if u is None:
            raise ValidationError(f"Unknown user '{ident_str}'.")
        resolved_users[u.id] = u

    total_count = len(resolved_users)
    cap = getattr(settings, "GROUP_SIZE_CAP", 20)
    if total_count > cap:
        raise ValidationError(
            f"Group size cannot exceed {cap} members (attempted {total_count})."
        )

    with transaction.atomic():
        conv = Conversation.objects.create(
            type=Conversation.TYPE_GROUP,
            name=cleaned_name,
            next_seq=1,
        )

        # Creator is admin
        Membership.objects.create(
            conversation=conv,
            user=creator,
            role=Membership.ROLE_ADMIN,
            joined_at_seq=0,
        )

        # Other members
        for uid, user_obj in resolved_users.items():
            if uid != creator.id:
                Membership.objects.create(
                    conversation=conv,
                    user=user_obj,
                    role=Membership.ROLE_MEMBER,
                    joined_at_seq=0,
                )

        # Initial system message
        sys_msg = _create_system_message(
            conv,
            creator,
            "group_created",
            f'{creator.display_name or creator.username} created the group "{cleaned_name}"',
        )

        all_member_ids = list(resolved_users.keys())

        # Broadcast initial system message and membership event
        sys_payload = _make_message_payload(sys_msg, creator)
        _broadcast_to_users(all_member_ids, "chat.message", sys_payload)
        _broadcast_to_users(
            all_member_ids,
            "membership.added",
            {
                "conversation_id": str(conv.id),
                "added_by": str(creator.id),
                "members": [
                    {
                        "user_id": str(u.id),
                        "username": u.username,
                        "display_name": u.display_name or u.username,
                        "role": "admin" if u.id == creator.id else "member",
                    }
                    for u in resolved_users.values()
                ],
            },
        )

        return conv


def add_group_members(
    actor: Any,
    conversation_id: Any,
    member_identifiers: List[Any],
) -> List[Membership]:
    with transaction.atomic():
        try:
            conv = Conversation.objects.select_for_update().get(id=conversation_id)
        except Conversation.DoesNotExist:
            raise NotFoundError("Conversation not found.")

        if conv.type != Conversation.TYPE_GROUP:
            raise ValidationError("Cannot add members to a DM.")

        # Require admin
        is_admin = Membership.objects.filter(
            conversation=conv,
            user=actor,
            role=Membership.ROLE_ADMIN,
        ).exists()
        if not is_admin:
            raise PermissionDenied("Only admins can add members to this group.")

        existing_user_ids = set(
            Membership.objects.filter(conversation=conv).values_list(
                "user_id", flat=True
            )
        )

        new_users: List[Any] = []
        seen_ids = set()
        for ident in member_identifiers:
            ident_str = str(ident).strip()
            if not ident_str:
                continue
            u = None
            try:
                val_uuid = uuid.UUID(ident_str)
                u = User.objects.filter(id=val_uuid).first()
            except ValueError:
                pass
            if u is None:
                u = User.objects.filter(username__iexact=ident_str).first()
            if u is None:
                raise ValidationError(f"Unknown user '{ident_str}'.")

            if u.id in existing_user_ids or u.id in seen_ids:
                continue
            seen_ids.add(u.id)
            new_users.append(u)

        if not new_users:
            return []

        cap = getattr(settings, "GROUP_SIZE_CAP", 20)
        current_count = len(existing_user_ids)
        if current_count + len(new_users) > cap:
            raise ValidationError(
                f"Group size cannot exceed {cap} members. Currently {current_count}, adding {len(new_users)}."
            )

        # Amendment 8: joined_at_seq computed BEFORE the "added" system message
        joined_at_seq = conv.next_seq - 1

        created_memberships = []
        for u in new_users:
            m = Membership.objects.create(
                conversation=conv,
                user=u,
                role=Membership.ROLE_MEMBER,
                joined_at_seq=joined_at_seq,
                last_delivered_seq=joined_at_seq,
                last_read_seq=joined_at_seq,
            )
            created_memberships.append(m)

        # Create system message
        names = ", ".join(u.display_name or u.username for u in new_users)
        target_ids = [str(u.id) for u in new_users]
        sys_msg = _create_system_message(
            conv,
            actor,
            "members_added",
            f"{actor.display_name or actor.username} added {names}",
            target_ids=target_ids,
        )

        # Fan-out inside the locked transaction (Amendment 10)
        all_member_ids = list(
            Membership.objects.filter(conversation=conv).values_list(
                "user_id", flat=True
            )
        )

        sys_payload = _make_message_payload(sys_msg, actor)
        _broadcast_to_users(all_member_ids, "chat.message", sys_payload)
        _broadcast_to_users(
            all_member_ids,
            "membership.added",
            {
                "conversation_id": str(conv.id),
                "added_by": str(actor.id),
                "members": [
                    {
                        "user_id": str(u.id),
                        "username": u.username,
                        "display_name": u.display_name or u.username,
                        "role": "member",
                    }
                    for u in new_users
                ],
            },
        )

        return created_memberships


def remove_group_member(
    actor: Any,
    conversation_id: Any,
    target_user_id: Any,
) -> None:
    with transaction.atomic():
        try:
            conv = Conversation.objects.select_for_update().get(id=conversation_id)
        except Conversation.DoesNotExist:
            raise NotFoundError("Conversation not found.")

        if conv.type != Conversation.TYPE_GROUP:
            raise ValidationError("Cannot remove members from a DM.")

        # Require admin
        is_admin = Membership.objects.filter(
            conversation=conv,
            user=actor,
            role=Membership.ROLE_ADMIN,
        ).exists()
        if not is_admin:
            raise PermissionDenied("Only admins can remove members.")

        if str(actor.id) == str(target_user_id):
            raise ValidationError("Cannot remove yourself; use leave instead.")

        target_m = (
            Membership.objects.filter(conversation=conv, user_id=target_user_id)
            .select_related("user")
            .first()
        )
        if not target_m:
            raise ValidationError("User is not a member of this group.")

        # Admin-removes-admin check (cannot remove the last admin)
        if target_m.role == Membership.ROLE_ADMIN:
            other_admins = (
                Membership.objects.filter(conversation=conv, role=Membership.ROLE_ADMIN)
                .exclude(user_id=target_user_id)
                .count()
            )
            if other_admins == 0:
                raise ValidationError("Cannot remove the last admin.")

        target_user = target_m.user
        target_m.delete()

        # System message
        sys_msg = _create_system_message(
            conv,
            actor,
            "member_removed",
            f"{actor.display_name or actor.username} removed {target_user.display_name or target_user.username}",
            target_ids=[str(target_user_id)],
        )

        remaining_member_ids = list(
            Membership.objects.filter(conversation=conv).values_list(
                "user_id", flat=True
            )
        )

        # Removed member receives membership.removed event so client can discard outbox and close view
        _broadcast_to_users(
            remaining_member_ids + [target_user_id],
            "membership.removed",
            {
                "conversation_id": str(conv.id),
                "removed_by": str(actor.id),
                "user_id": str(target_user_id),
            },
        )
        # System message is sent to remaining members only
        sys_payload = _make_message_payload(sys_msg, actor)
        _broadcast_to_users(remaining_member_ids, "chat.message", sys_payload)


def leave_group(
    actor: Any,
    conversation_id: Any,
) -> Tuple[bool, bool]:
    """
    Returns (left_successfully, group_deleted).
    """
    with transaction.atomic():
        try:
            conv = Conversation.objects.select_for_update().get(id=conversation_id)
        except Conversation.DoesNotExist:
            raise NotFoundError("Conversation not found.")

        if conv.type != Conversation.TYPE_GROUP:
            raise ValidationError("Cannot leave a DM.")

        m = Membership.objects.filter(conversation=conv, user=actor).first()
        if not m:
            raise NotAMemberError("You are not a member of this conversation.")

        # Last-admin rule (Amendment 1 / ADR 0022)
        if m.role == Membership.ROLE_ADMIN:
            other_admins = (
                Membership.objects.filter(conversation=conv, role=Membership.ROLE_ADMIN)
                .exclude(user=actor)
                .count()
            )
            other_members = (
                Membership.objects.filter(conversation=conv).exclude(user=actor).count()
            )
            if other_members > 0 and other_admins == 0:
                raise ValidationError(
                    "The last admin cannot leave. Promote another member to admin before leaving."
                )

        m.delete()

        remaining_member_ids = list(
            Membership.objects.filter(conversation=conv).values_list(
                "user_id", flat=True
            )
        )

        # When the last member leaves, delete the empty group in the same transaction (Amendment 1)
        if len(remaining_member_ids) == 0:
            conv.delete()
            _broadcast_to_users(
                [actor.id],
                "membership.removed",
                {
                    "conversation_id": str(conversation_id),
                    "removed_by": str(actor.id),
                    "user_id": str(actor.id),
                },
            )
            return True, True

        # Create system message
        sys_msg = _create_system_message(
            conv,
            actor,
            "member_left",
            f"{actor.display_name or actor.username} left the group",
            target_ids=[str(actor.id)],
        )

        _broadcast_to_users(
            remaining_member_ids + [actor.id],
            "membership.removed",
            {
                "conversation_id": str(conv.id),
                "removed_by": str(actor.id),
                "user_id": str(actor.id),
            },
        )
        sys_payload = _make_message_payload(sys_msg, actor)
        _broadcast_to_users(remaining_member_ids, "chat.message", sys_payload)

        return True, False


def change_member_role(
    actor: Any,
    conversation_id: Any,
    target_user_id: Any,
    new_role: str,
) -> Membership:
    if new_role not in (Membership.ROLE_ADMIN, Membership.ROLE_MEMBER):
        raise ValidationError(f"Invalid role '{new_role}'.")

    with transaction.atomic():
        try:
            conv = Conversation.objects.select_for_update().get(id=conversation_id)
        except Conversation.DoesNotExist:
            raise NotFoundError("Conversation not found.")

        if conv.type != Conversation.TYPE_GROUP:
            raise ValidationError("Cannot change roles in a DM.")

        # Require admin
        is_admin = Membership.objects.filter(
            conversation=conv,
            user=actor,
            role=Membership.ROLE_ADMIN,
        ).exists()
        if not is_admin:
            raise PermissionDenied("Only admins can change member roles.")

        target_m = (
            Membership.objects.filter(conversation=conv, user_id=target_user_id)
            .select_related("user")
            .first()
        )
        if not target_m:
            raise ValidationError("User is not a member of this group.")

        if target_m.role == new_role:
            return target_m

        # Cannot demote the last admin (Amendment 1)
        if (
            target_m.role == Membership.ROLE_ADMIN
            and new_role == Membership.ROLE_MEMBER
        ):
            other_admins = (
                Membership.objects.filter(conversation=conv, role=Membership.ROLE_ADMIN)
                .exclude(user_id=target_user_id)
                .count()
            )
            if other_admins == 0:
                raise ValidationError("Cannot demote the last admin.")

        target_m.role = new_role
        target_m.save(update_fields=["role"])

        action_text = "promoted" if new_role == Membership.ROLE_ADMIN else "demoted"
        kind = (
            "member_promoted" if new_role == Membership.ROLE_ADMIN else "member_demoted"
        )
        to_role = "an admin" if new_role == Membership.ROLE_ADMIN else "a member"

        sys_msg = _create_system_message(
            conv,
            actor,
            kind,
            f"{actor.display_name or actor.username} {action_text} {target_m.user.display_name or target_m.user.username} to {to_role}",
            target_ids=[str(target_user_id)],
        )

        all_member_ids = list(
            Membership.objects.filter(conversation=conv).values_list(
                "user_id", flat=True
            )
        )

        sys_payload = _make_message_payload(sys_msg, actor)
        _broadcast_to_users(all_member_ids, "chat.message", sys_payload)
        _broadcast_to_users(
            all_member_ids,
            "membership.updated",
            {
                "conversation_id": str(conv.id),
                "user_id": str(target_user_id),
                "role": new_role,
            },
        )

        return target_m


def rename_group(
    actor: Any,
    conversation_id: Any,
    new_name: str,
) -> Conversation:
    cleaned_name = new_name.strip() if new_name else ""
    if not cleaned_name:
        raise ValidationError("Group name cannot be empty.")
    if len(cleaned_name) > 50:
        raise ValidationError("Group name exceeds 50 characters.")

    with transaction.atomic():
        try:
            conv = Conversation.objects.select_for_update().get(id=conversation_id)
        except Conversation.DoesNotExist:
            raise NotFoundError("Conversation not found.")

        if conv.type != Conversation.TYPE_GROUP:
            raise ValidationError("Cannot rename a DM.")

        # Require admin
        is_admin = Membership.objects.filter(
            conversation=conv,
            user=actor,
            role=Membership.ROLE_ADMIN,
        ).exists()
        if not is_admin:
            raise PermissionDenied("Only admins can rename the group.")

        conv.name = cleaned_name
        conv.save(update_fields=["name", "updated_at"])

        sys_msg = _create_system_message(
            conv,
            actor,
            "group_renamed",
            f'{actor.display_name or actor.username} renamed the group to "{cleaned_name}"',
        )

        all_member_ids = list(
            Membership.objects.filter(conversation=conv).values_list(
                "user_id", flat=True
            )
        )

        sys_payload = _make_message_payload(sys_msg, actor)
        _broadcast_to_users(all_member_ids, "chat.message", sys_payload)
        _broadcast_to_users(
            all_member_ids,
            "conversation.updated",
            {
                "conversation_id": str(conv.id),
                "name": conv.name,
                "updated_by": str(actor.id),
            },
        )

        return conv


def broadcast_typing(
    actor: Any,
    conversation_id: Any,
    is_typing: bool,
) -> None:
    # Verify actor is a current member
    is_member = Membership.objects.filter(
        conversation_id=conversation_id,
        user=actor,
    ).exists()
    if not is_member:
        raise PermissionDenied("Not a member of this conversation.")

    other_member_ids = list(
        Membership.objects.filter(conversation_id=conversation_id)
        .exclude(user=actor)
        .values_list("user_id", flat=True)
    )

    channel_layer = get_channel_layer()
    if channel_layer is None:
        return

    event = {
        "type": "chat.typing",
        "payload": {
            "conversation_id": str(conversation_id),
            "user_id": str(actor.id),
            "username": actor.username,
            "display_name": actor.display_name or actor.username,
            "is_typing": bool(is_typing),
        },
    }

    for uid in other_member_ids:
        try:
            async_to_sync(channel_layer.group_send)(
                f"user_{uid}",
                event,
            )
        except Exception as e:
            logger.warning(
                "Failed to broadcast typing to user_%s group: %s",
                uid,
                e,
                exc_info=True,
            )


def update_membership_pointer(
    user: Any,
    conversation_id: Any,
    status_type: str,
    seq: int,
) -> Tuple[bool, int, int]:
    if seq <= 0:
        raise InvalidSeqError(f"Sequence number must be positive (received {seq}).")

    try:
        conversation = Conversation.objects.get(id=conversation_id)
    except Conversation.DoesNotExist:
        raise NotAMemberError("Conversation not found or not a member.")

    max_seq = conversation.next_seq - 1
    if seq > max_seq:
        raise InvalidSeqError(
            f"Sequence number {seq} exceeds conversation maximum of {max_seq}."
        )

    with transaction.atomic():
        membership_filter = Membership.objects.filter(
            conversation_id=conversation_id,
            user=user,
        )

        if not membership_filter.exists():
            raise NotAMemberError("User is not a member of this conversation.")

        if status_type == "read":
            rows_updated = membership_filter.filter(last_read_seq__lt=seq).update(
                last_read_seq=seq,
                last_delivered_seq=Greatest(F("last_delivered_seq"), seq),
            )
        elif status_type == "delivered":
            rows_updated = membership_filter.filter(last_delivered_seq__lt=seq).update(
                last_delivered_seq=seq,
            )
        else:
            return False, 0, 0

        if rows_updated == 0:
            membership = membership_filter.first()
            return (
                False,
                membership.last_delivered_seq if membership else 0,
                membership.last_read_seq if membership else 0,
            )

        membership = membership_filter.get()
        delivered_seq = membership.last_delivered_seq
        read_seq = membership.last_read_seq

        member_ids = list(
            Membership.objects.filter(conversation_id=conversation_id).values_list(
                "user_id", flat=True
            )
        )

        status_payload = {
            "conversation_id": str(conversation_id),
            "user_id": str(user.id),
            "delivered_seq": delivered_seq,
            "read_seq": read_seq,
        }

        _broadcast_to_users(member_ids, "chat.status", status_payload)

        return True, delivered_seq, read_seq


class NotFoundError(Exception):
    pass
