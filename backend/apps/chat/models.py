import uuid
from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models


def validate_message_body(value: str) -> None:
    if not value or not value.strip():
        raise ValidationError("Message body cannot be empty or whitespace only.")
    if len(value) > 4000:
        raise ValidationError("Message body exceeds 4000 character limit.")


class Conversation(models.Model):
    TYPE_DM = "dm"
    TYPE_GROUP = "group"
    TYPE_CHOICES = [
        (TYPE_DM, "Direct Message"),
        (TYPE_GROUP, "Group"),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    type = models.CharField(max_length=10, choices=TYPE_CHOICES, default=TYPE_DM)
    next_seq = models.IntegerField(default=1)
    dm_key = models.CharField(max_length=73, null=True, blank=True, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-updated_at"]

    def __str__(self) -> str:
        return f"Conversation({self.id}, type={self.type}, seq={self.next_seq})"


class Membership(models.Model):
    ROLE_ADMIN = "admin"
    ROLE_MEMBER = "member"
    ROLE_CHOICES = [
        (ROLE_ADMIN, "Admin"),
        (ROLE_MEMBER, "Member"),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    conversation = models.ForeignKey(
        Conversation,
        on_delete=models.CASCADE,
        related_name="memberships",
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="chat_memberships",
    )
    role = models.CharField(max_length=10, choices=ROLE_CHOICES, default=ROLE_MEMBER)
    last_delivered_seq = models.IntegerField(default=0)
    last_read_seq = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["conversation", "user"],
                name="unique_membership",
            )
        ]

    def __str__(self) -> str:
        return f"Membership(user={self.user_id}, conv={self.conversation_id}, role={self.role})"


class Message(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    conversation = models.ForeignKey(
        Conversation,
        on_delete=models.CASCADE,
        related_name="messages",
    )
    sender = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="sent_messages",
    )
    seq = models.IntegerField()
    body = models.TextField(validators=[validate_message_body])
    client_id = models.CharField(max_length=64)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["seq"]
        constraints = [
            models.UniqueConstraint(
                fields=["conversation", "seq"],
                name="unique_conversation_seq",
            ),
            models.UniqueConstraint(
                fields=["sender", "client_id"],
                name="unique_sender_client_id",
            ),
        ]
        indexes = [
            models.Index(fields=["conversation", "seq"], name="idx_conv_seq"),
        ]

    def __str__(self) -> str:
        return f"Message({self.id}, conv={self.conversation_id}, seq={self.seq}, sender={self.sender_id})"
