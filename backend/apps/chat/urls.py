from django.urls import path
from .views import (
    ConversationListView,
    ConversationMessagesView,
    DmConversationView,
)

urlpatterns = [
    path("conversations/dm", DmConversationView.as_view(), name="conversation-dm"),
    path("conversations", ConversationListView.as_view(), name="conversation-list"),
    path(
        "conversations/<uuid:conversation_id>/messages",
        ConversationMessagesView.as_view(),
        name="conversation-messages",
    ),
]
