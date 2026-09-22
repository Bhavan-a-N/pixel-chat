import uuid
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.db.models import Count, OuterRef, Prefetch, Subquery
from rest_framework import permissions, status
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Conversation, Membership, Message
from .serializers import (
    ConversationListSerializer,
    DmCreateSerializer,
    GroupAddMembersSerializer,
    GroupCreateSerializer,
    GroupDetailSerializer,
    GroupRenameSerializer,
    GroupRoleChangeSerializer,
    MessageSerializer,
)
from .services import (
    add_group_members,
    change_member_role,
    create_group,
    get_or_create_dm,
    leave_group,
    remove_group_member,
    rename_group,
)

User = get_user_model()


def get_presence_map_for_user_ids(user_ids):
    """
    Checks Redis keys presence:user:<user_id> for online status.
    """
    presence_map = {}
    for uid in user_ids:
        try:
            val = cache.get(f"presence:user:{uid}")
            presence_map[str(uid)] = bool(val)
        except Exception:
            presence_map[str(uid)] = False
    return presence_map


def get_conversations_annotated_queryset(user):
    user_membership_seq = Subquery(
        Membership.objects.filter(conversation=OuterRef("pk"), user=user).values(
            "joined_at_seq"
        )[:1]
    )

    member_count_subquery = Subquery(
        Membership.objects.filter(conversation=OuterRef("pk"))
        .values("conversation")
        .annotate(cnt=Count("id"))
        .values("cnt")[:1]
    )

    # Amendment 9: Apply joined_at_seq to the list's last-message preview
    last_msg = Message.objects.filter(
        conversation=OuterRef("pk"),
        seq__gt=OuterRef("user_joined_at_seq"),
    ).order_by("-seq")

    memberships_prefetch = Prefetch(
        "memberships",
        queryset=Membership.objects.select_related("user"),
        to_attr="prefetched_memberships",
    )

    return (
        Conversation.objects.filter(memberships__user=user)
        .annotate(
            user_joined_at_seq=user_membership_seq,
            member_count_annotated=member_count_subquery,
            last_message_id=Subquery(last_msg.values("id")[:1]),
            last_message_body=Subquery(last_msg.values("body")[:1]),
            last_message_sender_id=Subquery(last_msg.values("sender_id")[:1]),
            last_message_sender_display_name=Subquery(
                last_msg.values("sender__display_name")[:1]
            ),
            last_message_seq=Subquery(last_msg.values("seq")[:1]),
            last_message_client_id=Subquery(last_msg.values("client_id")[:1]),
            last_message_is_system=Subquery(last_msg.values("is_system")[:1]),
            last_message_created_at=Subquery(last_msg.values("created_at")[:1]),
        )
        .prefetch_related(memberships_prefetch)
        .distinct()
        .order_by("-updated_at")
    )


class DmConversationView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request):
        serializer = DmCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        target_username = serializer.validated_data["username"].strip()

        target_user = User.objects.filter(username__iexact=target_username).first()
        if not target_user:
            raise NotFound("User not found.")

        if target_user.id == request.user.id:
            raise ValidationError("Cannot DM yourself.")

        conversation, _ = get_or_create_dm(request.user, target_user)

        conv_with_annotations = (
            get_conversations_annotated_queryset(request.user)
            .filter(id=conversation.id)
            .first()
        )

        resp_serializer = ConversationListSerializer(
            conv_with_annotations,
            context={"request_user": request.user},
        )
        return Response(resp_serializer.data, status=status.HTTP_200_OK)


class GroupCreateView(APIView):
    permission_classes = [permissions.IsAuthenticated]
    throttle_scope = "group_create"

    def post(self, request):
        serializer = GroupCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        name = serializer.validated_data["name"]
        members = serializer.validated_data.get("members", [])

        conv = create_group(request.user, name, members)

        conv_with_annotations = (
            get_conversations_annotated_queryset(request.user)
            .filter(id=conv.id)
            .first()
        )

        resp_serializer = ConversationListSerializer(
            conv_with_annotations,
            context={"request_user": request.user},
        )
        return Response(resp_serializer.data, status=status.HTTP_201_CREATED)


class GroupDetailView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get_throttle_scope(self):
        if self.request.method == "PATCH":
            return "group_rename"
        return None

    def get(self, request, conversation_id):
        # Non-members get 404 (Amendment 9)
        m = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).first()
        if not m:
            raise NotFound("Conversation not found.")

        conv = (
            Conversation.objects.filter(id=conversation_id)
            .prefetch_related(
                Prefetch(
                    "memberships",
                    queryset=Membership.objects.select_related("user"),
                    to_attr="prefetched_memberships",
                )
            )
            .first()
        )
        if not conv or conv.type != Conversation.TYPE_GROUP:
            raise NotFound("Group conversation not found.")

        member_ids = [m.user_id for m in getattr(conv, "prefetched_memberships", [])]
        presence_map = get_presence_map_for_user_ids(member_ids)

        serializer = GroupDetailSerializer(
            conv,
            context={"request_user": request.user, "presence_map": presence_map},
        )
        return Response(serializer.data, status=status.HTTP_200_OK)

    def patch(self, request, conversation_id):
        serializer = GroupRenameSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        new_name = serializer.validated_data["name"]

        # Check membership and admin permissions
        is_member = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()
        if not is_member:
            raise NotFound("Conversation not found.")

        conv = rename_group(request.user, conversation_id, new_name)
        conv = (
            Conversation.objects.filter(id=conversation_id)
            .prefetch_related(
                Prefetch(
                    "memberships",
                    queryset=Membership.objects.select_related("user"),
                    to_attr="prefetched_memberships",
                )
            )
            .first()
        )
        member_ids = [m.user_id for m in getattr(conv, "prefetched_memberships", [])]
        presence_map = get_presence_map_for_user_ids(member_ids)

        resp_serializer = GroupDetailSerializer(
            conv,
            context={"request_user": request.user, "presence_map": presence_map},
        )
        return Response(resp_serializer.data, status=status.HTTP_200_OK)


class GroupMembersView(APIView):
    permission_classes = [permissions.IsAuthenticated]
    throttle_scope = "group_membership"

    def post(self, request, conversation_id):
        is_member = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()
        if not is_member:
            raise NotFound("Conversation not found.")

        serializer = GroupAddMembersSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        members_to_add = serializer.validated_data["members"]

        add_group_members(request.user, conversation_id, members_to_add)

        conv = (
            Conversation.objects.filter(id=conversation_id)
            .prefetch_related(
                Prefetch(
                    "memberships",
                    queryset=Membership.objects.select_related("user"),
                    to_attr="prefetched_memberships",
                )
            )
            .first()
        )
        member_ids = [m.user_id for m in getattr(conv, "prefetched_memberships", [])]
        presence_map = get_presence_map_for_user_ids(member_ids)

        resp_serializer = GroupDetailSerializer(
            conv,
            context={"request_user": request.user, "presence_map": presence_map},
        )
        return Response(resp_serializer.data, status=status.HTTP_200_OK)


class GroupMemberRemoveView(APIView):
    permission_classes = [permissions.IsAuthenticated]
    throttle_scope = "group_membership"

    def delete(self, request, conversation_id, user_id):
        is_member = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()
        if not is_member:
            raise NotFound("Conversation not found.")

        remove_group_member(request.user, conversation_id, user_id)
        return Response(status=status.HTTP_204_NO_CONTENT)


class GroupMemberRoleView(APIView):
    permission_classes = [permissions.IsAuthenticated]
    throttle_scope = "group_membership"

    def patch(self, request, conversation_id, user_id):
        is_member = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()
        if not is_member:
            raise NotFound("Conversation not found.")

        serializer = GroupRoleChangeSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        new_role = serializer.validated_data["role"]

        m = change_member_role(request.user, conversation_id, user_id, new_role)
        return Response(
            {
                "user_id": str(m.user_id),
                "role": m.role,
            },
            status=status.HTTP_200_OK,
        )


class GroupLeaveView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request, conversation_id):
        is_member = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()
        if not is_member:
            raise NotFound("Conversation not found.")

        left, deleted = leave_group(request.user, conversation_id)
        return Response(
            {
                "left": left,
                "deleted": deleted,
            },
            status=status.HTTP_200_OK,
        )


class UserPresenceView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        user_ids_param = request.query_params.get("user_ids", "")
        if not user_ids_param:
            return Response({}, status=status.HTTP_200_OK)

        raw_ids = [uid.strip() for uid in user_ids_param.split(",") if uid.strip()]
        requested_uuids = set()
        for raw_id in raw_ids:
            try:
                requested_uuids.add(uuid.UUID(raw_id))
            except ValueError:
                continue

        # Amendment 5: Scope includes people sharing ANY conversation (groups too)
        shared_conversation_user_ids = set(
            Membership.objects.filter(
                conversation__memberships__user=request.user
            ).values_list("user_id", flat=True)
        )

        valid_user_ids = requested_uuids.intersection(shared_conversation_user_ids)
        presence_map = get_presence_map_for_user_ids(valid_user_ids)
        return Response(presence_map, status=status.HTTP_200_OK)


class ConversationListView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request):
        conversations = get_conversations_annotated_queryset(request.user)

        serializer = ConversationListSerializer(
            conversations,
            many=True,
            context={"request_user": request.user},
        )
        return Response(serializer.data, status=status.HTTP_200_OK)


class ConversationMessagesView(APIView):
    permission_classes = [permissions.IsAuthenticated]

    def get(self, request, conversation_id):
        # Non-members get 404 (Amendment 9)
        m = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).first()

        if not m:
            raise NotFound("Conversation not found.")

        limit_param = request.query_params.get("limit", "30")
        try:
            limit = int(limit_param)
            limit = max(1, min(limit, 100))
        except ValueError:
            limit = 30

        after_seq_param = request.query_params.get("after_seq")
        before_seq_param = request.query_params.get("before_seq")

        # Amendment 9: Apply joined_at_seq to before_seq/after_seq pagination
        base_qs = Message.objects.filter(
            conversation_id=conversation_id,
            seq__gt=m.joined_at_seq,
        ).select_related("sender")

        if after_seq_param is not None:
            try:
                after_seq = int(after_seq_param)
            except ValueError:
                raise ValidationError("after_seq must be an integer.")
            effective_after = max(m.joined_at_seq, after_seq)
            messages = base_qs.filter(seq__gt=effective_after).order_by("seq")[:limit]
        elif before_seq_param is not None:
            try:
                before_seq = int(before_seq_param)
            except ValueError:
                raise ValidationError("before_seq must be an integer.")
            messages = base_qs.filter(seq__lt=before_seq).order_by("-seq")[:limit]
        else:
            messages = base_qs.order_by("-seq")[:limit]

        serializer = MessageSerializer(messages, many=True)
        return Response(serializer.data, status=status.HTTP_200_OK)
