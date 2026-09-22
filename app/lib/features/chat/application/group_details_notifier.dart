import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/chat_models.dart';
import 'conversations_notifier.dart';
import 'websocket_provider.dart';

class GroupDetailsState {
  const GroupDetailsState({this.detail, this.isLoading = false, this.error});

  final GroupDetail? detail;
  final bool isLoading;
  final String? error;

  GroupDetailsState copyWith({
    GroupDetail? detail,
    bool? isLoading,
    String? error,
  }) {
    return GroupDetailsState(
      detail: detail ?? this.detail,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class GroupDetailsNotifier extends Notifier<GroupDetailsState> {
  GroupDetailsNotifier(this.conversationId);

  final String conversationId;
  StreamSubscription<WsEnvelope>? _eventsSub;

  @override
  GroupDetailsState build() {
    ref.onDispose(() {
      _eventsSub?.cancel();
      _eventsSub = null;
    });

    _setupWebSocketListener();
    load();
    return const GroupDetailsState(isLoading: true);
  }

  void _setupWebSocketListener() {
    final client = ref.read(chatWebSocketClientProvider);
    _eventsSub = client.incomingEvents.listen((envelope) {
      final payload = envelope.payload;
      final convId = payload['conversation_id'] as String?;
      if (convId != conversationId) return;

      if (envelope.type == 'membership.added' ||
          envelope.type == 'membership.removed' ||
          envelope.type == 'membership.updated' ||
          envelope.type == 'conversation.updated') {
        load();
      }
    });
  }

  Future<void> load() async {
    try {
      final repo = ref.read(chatRepositoryProvider);
      final detail = await repo.getGroupDetail(conversationId);

      // Fetch latest presence for all members
      final memberIds = detail.members.map((m) => m.id).toList();
      final presenceMap = await repo.getPresence(memberIds);

      final membersWithPresence = detail.members.map((m) {
        final isOnline = presenceMap[m.id] ?? m.isOnline;
        return m.copyWith(isOnline: isOnline);
      }).toList();

      state = state.copyWith(
        detail: detail.copyWith(members: membersWithPresence),
        isLoading: false,
        error: null,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> renameGroup(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed.length > 50) return;

    try {
      final repo = ref.read(chatRepositoryProvider);
      final updated = await repo.renameGroup(conversationId, trimmed);
      state = state.copyWith(detail: updated);
      // Also update conversations list
      ref.read(conversationsNotifierProvider.notifier).load();
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  Future<void> addMembers(List<String> identifiers) async {
    if (identifiers.isEmpty) return;
    try {
      final repo = ref.read(chatRepositoryProvider);
      final updated = await repo.addGroupMembers(conversationId, identifiers);
      state = state.copyWith(detail: updated);
      ref.read(conversationsNotifierProvider.notifier).load();
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  Future<void> removeMember(String userId) async {
    try {
      final repo = ref.read(chatRepositoryProvider);
      await repo.removeGroupMember(conversationId, userId);
      final currentDetail = state.detail;
      if (currentDetail != null) {
        final updatedMembers = currentDetail.members
            .where((m) => m.id != userId)
            .toList();
        state = state.copyWith(
          detail: currentDetail.copyWith(
            members: updatedMembers,
            memberCount: updatedMembers.length,
          ),
        );
      }
      ref.read(conversationsNotifierProvider.notifier).load();
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  Future<void> changeRole(String userId, String newRole) async {
    try {
      final repo = ref.read(chatRepositoryProvider);
      await repo.changeMemberRole(conversationId, userId, newRole);
      final currentDetail = state.detail;
      if (currentDetail != null) {
        final updatedMembers = currentDetail.members.map((m) {
          if (m.id == userId) {
            return m.copyWith(role: newRole);
          }
          return m;
        }).toList();
        state = state.copyWith(
          detail: currentDetail.copyWith(members: updatedMembers),
        );
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }

  Future<void> leaveGroup() async {
    try {
      final repo = ref.read(chatRepositoryProvider);
      await repo.leaveGroup(conversationId);
      ref
          .read(conversationsNotifierProvider.notifier)
          .removeConversation(conversationId);
    } catch (e) {
      state = state.copyWith(error: e.toString());
      rethrow;
    }
  }
}

final groupDetailsNotifierProvider =
    NotifierProvider.family<GroupDetailsNotifier, GroupDetailsState, String>(
      (arg) => GroupDetailsNotifier(arg),
    );
