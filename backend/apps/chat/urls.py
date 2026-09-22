from django.urls import path
from .views import (
    ConversationListView,
    ConversationMessagesView,
    DmConversationView,
    GroupCreateView,
    GroupDetailView,
    GroupLeaveView,
    GroupMemberRemoveView,
    GroupMemberRoleView,
    GroupMembersView,
    UserPresenceView,
)

urlpatterns = [
    path("conversations/dm", DmConversationView.as_view(), name="conversation-dm"),
    path(
        "conversations/group",
        GroupCreateView.as_view(),
        name="conversation-group-create",
    ),
    path("conversations", ConversationListView.as_view(), name="conversation-list"),
    path(
        "conversations/<uuid:conversation_id>",
        GroupDetailView.as_view(),
        name="conversation-detail",
    ),
    path(
        "conversations/<uuid:conversation_id>/members",
        GroupMembersView.as_view(),
        name="conversation-members",
    ),
    path(
        "conversations/<uuid:conversation_id>/members/<uuid:user_id>",
        GroupMemberRemoveView.as_view(),
        name="conversation-member-remove",
    ),
    path(
        "conversations/<uuid:conversation_id>/members/<uuid:user_id>/role",
        GroupMemberRoleView.as_view(),
        name="conversation-member-role",
    ),
    path(
        "conversations/<uuid:conversation_id>/leave",
        GroupLeaveView.as_view(),
        name="conversation-leave",
    ),
    path(
        "conversations/<uuid:conversation_id>/messages",
        ConversationMessagesView.as_view(),
        name="conversation-messages",
    ),
    path("users/presence", UserPresenceView.as_view(), name="user-presence"),
]
