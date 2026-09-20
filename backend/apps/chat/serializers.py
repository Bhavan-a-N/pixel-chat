from rest_framework import serializers
from apps.accounts.serializers import UserSerializer
from .models import Conversation, Message


class MessageSerializer(serializers.ModelSerializer):
    conversation_id = serializers.UUIDField(source="conversation.id", read_only=True)
    sender_id = serializers.UUIDField(source="sender.id", read_only=True)

    class Meta:
        model = Message
        fields = [
            "id",
            "conversation_id",
            "sender_id",
            "seq",
            "body",
            "client_id",
            "created_at",
        ]
        read_only_fields = fields


class DmCreateSerializer(serializers.Serializer):
    username = serializers.CharField(max_length=20, required=True)


class ConversationListSerializer(serializers.ModelSerializer):
    other_participant = serializers.SerializerMethodField()
    last_message = serializers.SerializerMethodField()
    last_seq = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            "id",
            "type",
            "other_participant",
            "last_message",
            "last_seq",
            "created_at",
            "updated_at",
        ]

    def get_other_participant(self, obj: Conversation):
        request_user = self.context.get("request_user")
        if not request_user:
            return None

        # Uses prefetched memberships to avoid queries
        for membership in getattr(obj, "prefetched_memberships", []):
            if membership.user_id != request_user.id:
                return UserSerializer(membership.user).data
        return None

    def get_last_message(self, obj: Conversation):
        if getattr(obj, "last_message_id", None) is not None:
            created_at = obj.last_message_created_at
            created_at_str = (
                created_at.isoformat()
                if hasattr(created_at, "isoformat")
                else str(created_at)
            )
            return {
                "id": str(obj.last_message_id),
                "conversation_id": str(obj.id),
                "sender_id": str(obj.last_message_sender_id),
                "seq": obj.last_message_seq,
                "body": obj.last_message_body,
                "client_id": obj.last_message_client_id,
                "created_at": created_at_str,
            }
        return None

    def get_last_seq(self, obj: Conversation) -> int:
        return max(0, obj.next_seq - 1)
