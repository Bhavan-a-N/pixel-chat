from rest_framework import serializers
from apps.accounts.serializers import UserSerializer
from .models import Conversation, Membership, Message


class MessageSerializer(serializers.ModelSerializer):
    conversation_id = serializers.UUIDField(source="conversation.id", read_only=True)
    sender_id = serializers.UUIDField(source="sender.id", read_only=True)
    sender_display_name = serializers.SerializerMethodField()
    sender_avatar_seed = serializers.SerializerMethodField()

    class Meta:
        model = Message
        fields = [
            "id",
            "conversation_id",
            "sender_id",
            "sender_display_name",
            "sender_avatar_seed",
            "seq",
            "body",
            "client_id",
            "is_system",
            "system_data",
            "created_at",
        ]
        read_only_fields = fields

    def get_sender_display_name(self, obj: Message) -> str:
        if (
            hasattr(obj, "sender_display_name_annotated")
            and obj.sender_display_name_annotated
        ):
            return obj.sender_display_name_annotated
        return getattr(obj.sender, "display_name", "") or obj.sender.username

    def get_sender_avatar_seed(self, obj: Message) -> str:
        if (
            hasattr(obj, "sender_avatar_seed_annotated")
            and obj.sender_avatar_seed_annotated
        ):
            return obj.sender_avatar_seed_annotated
        return getattr(obj.sender, "avatar_seed", "")


class DmCreateSerializer(serializers.Serializer):
    username = serializers.CharField(max_length=20, required=True)


class GroupCreateSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=50, required=True)
    members = serializers.ListField(
        child=serializers.CharField(),
        required=False,
        default=list,
    )


class GroupRenameSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=50, required=True)


class GroupAddMembersSerializer(serializers.Serializer):
    members = serializers.ListField(
        child=serializers.CharField(),
        required=True,
        min_length=1,
    )


class GroupRoleChangeSerializer(serializers.Serializer):
    role = serializers.ChoiceField(
        choices=[Membership.ROLE_ADMIN, Membership.ROLE_MEMBER],
        required=True,
    )


class GroupMemberDetailSerializer(serializers.ModelSerializer):
    id = serializers.UUIDField(source="user.id", read_only=True)
    username = serializers.CharField(source="user.username", read_only=True)
    display_name = serializers.CharField(source="user.display_name", read_only=True)
    avatar_seed = serializers.CharField(source="user.avatar_seed", read_only=True)
    is_online = serializers.SerializerMethodField()

    class Meta:
        model = Membership
        fields = [
            "id",
            "username",
            "display_name",
            "avatar_seed",
            "role",
            "joined_at_seq",
            "last_delivered_seq",
            "last_read_seq",
            "is_online",
        ]
        read_only_fields = fields

    def get_is_online(self, obj: Membership) -> bool:
        presence_map = self.context.get("presence_map", {})
        return bool(presence_map.get(str(obj.user_id), False))


class GroupDetailSerializer(serializers.ModelSerializer):
    members = serializers.SerializerMethodField()
    member_count = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            "id",
            "type",
            "name",
            "member_count",
            "members",
            "created_at",
            "updated_at",
        ]

    def get_member_count(self, obj: Conversation) -> int:
        if hasattr(obj, "member_count_annotated"):
            return obj.member_count_annotated or 0
        memberships = getattr(obj, "prefetched_memberships", None)
        if memberships is not None:
            return len(memberships)
        return obj.memberships.count()

    def get_members(self, obj: Conversation):
        memberships = getattr(obj, "prefetched_memberships", None)
        if memberships is None:
            memberships = obj.memberships.select_related("user").all()
        return GroupMemberDetailSerializer(
            memberships,
            many=True,
            context=self.context,
        ).data


class ConversationListSerializer(serializers.ModelSerializer):
    name = serializers.CharField(read_only=True)
    member_count = serializers.SerializerMethodField()
    other_participant = serializers.SerializerMethodField()
    last_message = serializers.SerializerMethodField()
    last_seq = serializers.SerializerMethodField()
    memberships = serializers.SerializerMethodField()
    other_delivered_seq = serializers.SerializerMethodField()
    other_read_seq = serializers.SerializerMethodField()

    class Meta:
        model = Conversation
        fields = [
            "id",
            "type",
            "name",
            "member_count",
            "other_participant",
            "last_message",
            "last_seq",
            "memberships",
            "other_delivered_seq",
            "other_read_seq",
            "created_at",
            "updated_at",
        ]

    def get_member_count(self, obj: Conversation) -> int:
        if (
            hasattr(obj, "member_count_annotated")
            and obj.member_count_annotated is not None
        ):
            return obj.member_count_annotated
        memberships = getattr(obj, "prefetched_memberships", None)
        if memberships is not None:
            return len(memberships)
        return obj.memberships.count()

    def get_memberships(self, obj: Conversation):
        memberships = getattr(obj, "prefetched_memberships", None)
        if memberships is None:
            memberships = obj.memberships.all()
        return [
            {
                "user_id": str(m.user_id),
                "role": m.role,
                "last_delivered_seq": m.last_delivered_seq,
                "last_read_seq": m.last_read_seq,
            }
            for m in memberships
        ]

    def get_other_participant(self, obj: Conversation):
        if obj.type != Conversation.TYPE_DM:
            return None
        request_user = self.context.get("request_user")
        if not request_user:
            return None

        for membership in getattr(obj, "prefetched_memberships", []):
            if membership.user_id != request_user.id:
                return UserSerializer(membership.user).data
        return None

    def get_other_delivered_seq(self, obj: Conversation) -> int:
        request_user = self.context.get("request_user")
        if not request_user:
            return 0
        for m in getattr(obj, "prefetched_memberships", []):
            if m.user_id != request_user.id:
                return m.last_delivered_seq
        return 0

    def get_other_read_seq(self, obj: Conversation) -> int:
        request_user = self.context.get("request_user")
        if not request_user:
            return 0
        for m in getattr(obj, "prefetched_memberships", []):
            if m.user_id != request_user.id:
                return m.last_read_seq
        return 0

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
                "sender_display_name": getattr(
                    obj, "last_message_sender_display_name", ""
                )
                or "",
                "seq": obj.last_message_seq,
                "body": obj.last_message_body,
                "client_id": obj.last_message_client_id,
                "is_system": getattr(obj, "last_message_is_system", False),
                "created_at": created_at_str,
            }
        return None

    def get_last_seq(self, obj: Conversation) -> int:
        return max(0, obj.next_seq - 1)
