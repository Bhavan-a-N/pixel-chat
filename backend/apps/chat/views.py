from django.contrib.auth import get_user_model
from django.db.models import OuterRef, Prefetch, Subquery
from rest_framework import permissions, status
from rest_framework.exceptions import NotFound, ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Conversation, Membership, Message
from .serializers import (
    ConversationListSerializer,
    DmCreateSerializer,
    MessageSerializer,
)
from .services import get_or_create_dm

User = get_user_model()


def get_conversations_annotated_queryset(user):
    last_msg = Message.objects.filter(conversation=OuterRef("pk")).order_by("-seq")

    memberships_prefetch = Prefetch(
        "memberships",
        queryset=Membership.objects.select_related("user"),
        to_attr="prefetched_memberships",
    )

    return (
        Conversation.objects.filter(memberships__user=user)
        .annotate(
            last_message_id=Subquery(last_msg.values("id")[:1]),
            last_message_body=Subquery(last_msg.values("body")[:1]),
            last_message_sender_id=Subquery(last_msg.values("sender_id")[:1]),
            last_message_seq=Subquery(last_msg.values("seq")[:1]),
            last_message_client_id=Subquery(last_msg.values("client_id")[:1]),
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
        # Verify caller membership; non-members get 404 to avoid leaking existence
        is_member = Membership.objects.filter(
            conversation_id=conversation_id,
            user=request.user,
        ).exists()

        if not is_member:
            raise NotFound("Conversation not found.")

        limit_param = request.query_params.get("limit", "30")
        try:
            limit = int(limit_param)
            limit = max(1, min(limit, 100))
        except ValueError:
            limit = 30

        after_seq_param = request.query_params.get("after_seq")
        before_seq_param = request.query_params.get("before_seq")

        if after_seq_param is not None:
            try:
                after_seq = int(after_seq_param)
            except ValueError:
                raise ValidationError("after_seq must be an integer.")
            messages = Message.objects.filter(
                conversation_id=conversation_id,
                seq__gt=after_seq,
            ).order_by("seq")[:limit]
        elif before_seq_param is not None:
            try:
                before_seq = int(before_seq_param)
            except ValueError:
                raise ValidationError("before_seq must be an integer.")
            messages = Message.objects.filter(
                conversation_id=conversation_id,
                seq__lt=before_seq,
            ).order_by("-seq")[:limit]
        else:
            messages = Message.objects.filter(conversation_id=conversation_id).order_by(
                "-seq"
            )[:limit]

        serializer = MessageSerializer(messages, many=True)
        return Response(serializer.data, status=status.HTTP_200_OK)
