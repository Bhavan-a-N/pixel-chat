import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/network/websocket_client.dart';
import '../../auth/application/auth_notifier.dart';
import '../../auth/application/auth_state.dart';
import '../data/chat_repository.dart';
import '../domain/chat_models.dart';
import 'websocket_provider.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  final dio = ref.watch(mainDioProvider);
  return ChatRepositoryImpl(dio: dio);
});

class ActiveConversationNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setActive(String? id) {
    state = id;
  }
}

final activeConversationIdProvider =
    NotifierProvider<ActiveConversationNotifier, String?>(
      ActiveConversationNotifier.new,
    );

class ConversationsNotifier extends Notifier<AsyncValue<List<Conversation>>> {
  static const _uuid = Uuid();
  StreamSubscription<WsEnvelope>? _eventsSub;
  StreamSubscription<WebSocketConnectionState>? _wsStateSub;

  final Map<String, int> _lastDeliveredAckSent = {};
  final Map<String, int> _pendingDeliveredAcks = {};
  Timer? _deliveredAckTimer;

  @visibleForTesting
  int? lastDeliveredAckSent(String convId) => _lastDeliveredAckSent[convId];

  @override
  AsyncValue<List<Conversation>> build() {
    final authState = ref.watch(authNotifierProvider);
    if (authState.status != AuthStatus.authenticated) {
      _cancelSubscriptions();
      _lastDeliveredAckSent.clear();
      _pendingDeliveredAcks.clear();
      return const AsyncValue.data([]);
    }

    ref.onDispose(() {
      _cancelSubscriptions();
      _lastDeliveredAckSent.clear();
      _pendingDeliveredAcks.clear();
    });

    _setupSubscriptions();
    load();
    return const AsyncValue.loading();
  }

  void _setupSubscriptions() {
    _cancelSubscriptions();

    final client = ref.read(chatWebSocketClientProvider);

    // Refetch conversation list after each reconnect (Amendment 7)
    _wsStateSub = client.stateStream.listen((wsState) {
      if (wsState == WebSocketConnectionState.connected) {
        load();
      }
    });

    // Handle incoming message, status, and group events
    _eventsSub = client.incomingEvents.listen((envelope) {
      if (envelope.type == 'chat.receive') {
        _handleIncomingMessage(envelope);
      } else if (envelope.type == 'chat.status') {
        _handleIncomingStatus(envelope);
      } else if (envelope.type == 'membership.added') {
        load();
      } else if (envelope.type == 'membership.removed') {
        _handleMembershipRemoved(envelope);
      } else if (envelope.type == 'conversation.updated') {
        _handleConversationUpdated(envelope);
      }
    });
  }

  void _cancelSubscriptions() {
    _eventsSub?.cancel();
    _eventsSub = null;
    _wsStateSub?.cancel();
    _wsStateSub = null;
    _deliveredAckTimer?.cancel();
    _deliveredAckTimer = null;
  }

  Future<void> load() async {
    try {
      final repository = ref.read(chatRepositoryProvider);
      final rawConversations = await repository.getConversations();

      final authState = ref.read(authNotifierProvider);
      final currentUserId = authState.user?.id ?? '';
      final currentList = state.asData?.value ?? [];
      final activeId = ref.read(activeConversationIdProvider);
      final client = ref.read(chatWebSocketClientProvider);

      // Merge pointers monotonically with max(current, incoming)
      final mergedConversations = <Conversation>[];
      for (final incoming in rawConversations) {
        final existingIndex = currentList.indexWhere(
          (c) => c.id == incoming.id,
        );
        Conversation convToUse = incoming;

        if (existingIndex >= 0) {
          final existing = currentList[existingIndex];
          final mergedMemberships = incoming.memberships.map((m) {
            if (m.userId == currentUserId) {
              // Current user's tracking resets to server REST payload on reconnect (Amendment 2)
              return m;
            }
            final emIndex = existing.memberships.indexWhere(
              (em) => em.userId == m.userId,
            );
            if (emIndex >= 0) {
              final em = existing.memberships[emIndex];
              return m.copyWith(
                lastDeliveredSeq: math.max(
                  m.lastDeliveredSeq,
                  em.lastDeliveredSeq,
                ),
                lastReadSeq: math.max(m.lastReadSeq, em.lastReadSeq),
              );
            }
            return m;
          }).toList();

          convToUse = incoming.copyWith(
            otherDeliveredSeq: math.max(
              existing.otherDeliveredSeq,
              incoming.otherDeliveredSeq,
            ),
            otherReadSeq: math.max(
              existing.otherReadSeq,
              incoming.otherReadSeq,
            ),
            memberships: mergedMemberships,
          );
        }

        mergedConversations.add(convToUse);

        // Reset "last ack sent" to my own last_delivered_seq from memberships
        final myDelivered = convToUse.myDeliveredSeq(currentUserId);
        _lastDeliveredAckSent[convToUse.id] = myDelivered;

        // For non-viewed conversations, ack last_seq if last message is not mine
        // and last_seq is above my delivered pointer (no message fetch needed)
        if (convToUse.id != activeId) {
          final lastMsg = convToUse.lastMessage;
          final lastSeq = convToUse.lastSeq;
          if (lastMsg != null &&
              lastMsg.senderId != currentUserId &&
              lastSeq > myDelivered &&
              lastSeq > (_lastDeliveredAckSent[convToUse.id] ?? myDelivered)) {
            if (client.state == WebSocketConnectionState.connected) {
              final sent = client.sendEnvelope(
                WsEnvelope(
                  type: 'chat.delivered',
                  clientId: _uuid.v4(),
                  payload: {'conversation_id': convToUse.id, 'seq': lastSeq},
                ),
              );
              if (sent) {
                _lastDeliveredAckSent[convToUse.id] = lastSeq;
              }
            }
          }
        }
      }

      state = AsyncValue.data(mergedConversations);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  void _handleIncomingMessage(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    if (convId == null) return;

    final incomingMsg = ChatMessage.fromJson(payload);
    final authState = ref.read(authNotifierProvider);
    final currentUserId = authState.user?.id ?? '';

    // Schedule delivered ack if message is from another participant
    if (incomingMsg.senderId != currentUserId && incomingMsg.seq > 0) {
      _scheduleDeliveredAck(convId, incomingMsg.seq);
    }

    final currentList = state.asData?.value ?? [];
    final existingIndex = currentList.indexWhere((c) => c.id == convId);

    if (existingIndex == -1) {
      // Unknown conversation triggers a list refetch
      load();
      return;
    }

    final conv = currentList[existingIndex];
    final updatedConv = conv.copyWith(
      lastMessage: incomingMsg,
      lastSeq: math.max(conv.lastSeq, incomingMsg.seq),
      updatedAt: incomingMsg.createdAt,
    );

    final newList = List<Conversation>.from(currentList);
    newList.removeAt(existingIndex);
    newList.insert(0, updatedConv); // latest activity first
    state = AsyncValue.data(newList);
  }

  void _scheduleDeliveredAck(String convId, int seq) {
    final currentPending = _pendingDeliveredAcks[convId] ?? 0;
    _pendingDeliveredAcks[convId] = math.max(currentPending, seq);

    _deliveredAckTimer?.cancel();
    _deliveredAckTimer = Timer(
      const Duration(milliseconds: 300),
      _flushDeliveredAcks,
    );
  }

  void _flushDeliveredAcks() {
    final client = ref.read(chatWebSocketClientProvider);
    if (client.state != WebSocketConnectionState.connected) return;

    for (final entry in _pendingDeliveredAcks.entries) {
      final convId = entry.key;
      final seq = entry.value;
      final lastSent = _lastDeliveredAckSent[convId] ?? 0;

      if (seq > lastSent) {
        final sent = client.sendEnvelope(
          WsEnvelope(
            type: 'chat.delivered',
            clientId: _uuid.v4(),
            payload: {'conversation_id': convId, 'seq': seq},
          ),
        );
        if (sent) {
          _lastDeliveredAckSent[convId] =
              seq; // Set only when frame is actually sent
        }
      }
    }
    _pendingDeliveredAcks.clear();
  }

  void _handleIncomingStatus(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    final userId = payload['user_id'] as String?;
    final deliveredSeq = (payload['delivered_seq'] as num?)?.toInt() ?? 0;
    final readSeq = (payload['read_seq'] as num?)?.toInt() ?? 0;

    if (convId == null || userId == null) return;

    final currentList = state.asData?.value ?? [];
    final index = currentList.indexWhere((c) => c.id == convId);
    if (index == -1) return;

    final conv = currentList[index];
    final authState = ref.read(authNotifierProvider);
    final currentUserId = authState.user?.id ?? '';

    // Update memberships
    final updatedMemberships = conv.memberships.map((m) {
      if (m.userId == userId) {
        return m.copyWith(
          lastDeliveredSeq: math.max(m.lastDeliveredSeq, deliveredSeq),
          lastReadSeq: math.max(m.lastReadSeq, readSeq),
        );
      }
      return m;
    }).toList();

    // If membership not found in list, append it
    if (!updatedMemberships.any((m) => m.userId == userId)) {
      updatedMemberships.add(
        MembershipPointer(
          userId: userId,
          lastDeliveredSeq: deliveredSeq,
          lastReadSeq: readSeq,
        ),
      );
    }

    final updatedConv = conv.copyWith(
      otherDeliveredSeq: userId != currentUserId
          ? math.max(conv.otherDeliveredSeq, deliveredSeq)
          : conv.otherDeliveredSeq,
      otherReadSeq: userId != currentUserId
          ? math.max(conv.otherReadSeq, readSeq)
          : conv.otherReadSeq,
      memberships: updatedMemberships,
    );

    final newList = List<Conversation>.from(currentList);
    newList[index] = updatedConv;
    state = AsyncValue.data(newList);
  }

  void _handleMembershipRemoved(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    final userId = payload['user_id'] as String?;
    if (convId == null || userId == null) return;

    final authState = ref.read(authNotifierProvider);
    final currentUserId = authState.user?.id ?? '';

    if (userId == currentUserId) {
      // Current user was removed from the group
      removeConversation(convId);
    } else {
      // Another user was removed, refetch to update member count
      load();
    }
  }

  void _handleConversationUpdated(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    final newName = payload['name'] as String?;
    if (convId == null || newName == null) return;

    final currentList = state.asData?.value ?? [];
    final index = currentList.indexWhere((c) => c.id == convId);
    if (index == -1) return;

    final conv = currentList[index];
    final updatedConv = conv.copyWith(name: newName);
    final newList = List<Conversation>.from(currentList);
    newList[index] = updatedConv;
    state = AsyncValue.data(newList);
  }

  void removeConversation(String conversationId) {
    final currentList = state.asData?.value ?? [];
    final newList = currentList.where((c) => c.id != conversationId).toList();
    state = AsyncValue.data(newList);
  }

  Future<Conversation> createOrGetDm(String username) async {
    final repository = ref.read(chatRepositoryProvider);
    final conv = await repository.createOrGetDm(username);

    final currentList = state.asData?.value ?? [];
    final index = currentList.indexWhere((c) => c.id == conv.id);
    final newList = List<Conversation>.from(currentList);

    if (index >= 0) {
      newList[index] = conv;
    } else {
      newList.insert(0, conv);
    }
    state = AsyncValue.data(newList);
    return conv;
  }

  Future<Conversation> createGroup({
    required String name,
    required List<String> members,
  }) async {
    final repository = ref.read(chatRepositoryProvider);
    final conv = await repository.createGroup(name: name, members: members);

    final currentList = state.asData?.value ?? [];
    final index = currentList.indexWhere((c) => c.id == conv.id);
    final newList = List<Conversation>.from(currentList);

    if (index >= 0) {
      newList[index] = conv;
    } else {
      newList.insert(0, conv);
    }
    state = AsyncValue.data(newList);
    return conv;
  }
}

final conversationsNotifierProvider =
    NotifierProvider<ConversationsNotifier, AsyncValue<List<Conversation>>>(
      ConversationsNotifier.new,
    );
