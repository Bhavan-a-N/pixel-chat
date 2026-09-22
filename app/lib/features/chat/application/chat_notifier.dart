import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/network/websocket_client.dart';
import '../../auth/application/auth_notifier.dart';
import '../../auth/application/auth_state.dart';
import '../domain/chat_models.dart';
import 'conversations_notifier.dart';
import 'websocket_provider.dart';

class ChatMessagesState {
  const ChatMessagesState({
    this.messages = const [],
    this.isLoading = false,
    this.isLoadingOlder = false,
    this.hasMoreOlder = true,
    this.isCatchingUp = false,
    this.otherDeliveredSeq = 0,
    this.otherReadSeq = 0,
    this.isRemovedFromGroup = false,
    this.typingUsers = const {},
    this.error,
  });

  final List<ChatMessage> messages;
  final bool isLoading;
  final bool isLoadingOlder;
  final bool hasMoreOlder;
  final bool isCatchingUp;
  final int otherDeliveredSeq;
  final int otherReadSeq;
  final bool isRemovedFromGroup;
  final Map<String, String> typingUsers;
  final String? error;

  String? get typingText {
    if (typingUsers.isEmpty) return null;
    if (typingUsers.length == 1) {
      return '${typingUsers.values.first} is typing...';
    }
    return '${typingUsers.length} people are typing...';
  }

  ChatMessagesState copyWith({
    List<ChatMessage>? messages,
    bool? isLoading,
    bool? isLoadingOlder,
    bool? hasMoreOlder,
    bool? isCatchingUp,
    int? otherDeliveredSeq,
    int? otherReadSeq,
    bool? isRemovedFromGroup,
    Map<String, String>? typingUsers,
    String? error,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingOlder: isLoadingOlder ?? this.isLoadingOlder,
      hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
      isCatchingUp: isCatchingUp ?? this.isCatchingUp,
      otherDeliveredSeq: otherDeliveredSeq ?? this.otherDeliveredSeq,
      otherReadSeq: otherReadSeq ?? this.otherReadSeq,
      isRemovedFromGroup: isRemovedFromGroup ?? this.isRemovedFromGroup,
      typingUsers: typingUsers ?? this.typingUsers,
      error: error,
    );
  }
}

class ChatNotifier extends Notifier<ChatMessagesState> {
  ChatNotifier(this.conversationId);

  final String conversationId;
  static const _uuid = Uuid();
  StreamSubscription<WsEnvelope>? _eventsSub;
  StreamSubscription<WebSocketConnectionState>? _wsStateSub;

  final List<ChatMessage> _outbox = [];
  final List<WsEnvelope> _liveEventBuffer = [];
  bool _isFlushingOutbox = false;
  Timer? _rateLimitRetryTimer;
  int _lastReadAckSent = 0;
  Timer? _readAckTimer;
  bool _needsReadPointerResetOnReconnect = false;
  final Map<String, Timer> _typingTimers = {};

  @visibleForTesting
  int get lastReadAckSent => _lastReadAckSent;

  @override
  ChatMessagesState build() {
    final authState = ref.watch(authNotifierProvider);

    if (authState.status != AuthStatus.authenticated) {
      _cancelSubscriptions();
      _outbox.clear();
      _liveEventBuffer.clear();
      return const ChatMessagesState();
    }

    ref.onDispose(() {
      _cancelSubscriptions();
      _outbox.clear();
      _liveEventBuffer.clear();
    });

    ref.listen<AsyncValue<List<Conversation>>>(conversationsNotifierProvider, (
      previous,
      next,
    ) {
      if (_needsReadPointerResetOnReconnect) {
        _resetReadPointersFromConversations();
        _needsReadPointerResetOnReconnect = false;
      } else {
        _mergeOtherPointersFromConversations();
      }
    });

    _setupSubscriptions();
    loadInitial();
    return const ChatMessagesState(isLoading: true);
  }

  void _setupSubscriptions() {
    _cancelSubscriptions();
    final client = ref.read(chatWebSocketClientProvider);

    _wsStateSub = client.stateStream.listen((wsState) {
      if (wsState == WebSocketConnectionState.connected) {
        _needsReadPointerResetOnReconnect = true;
        _resetReadPointersFromConversations();
        // Trigger catch-up sync and outbox flush on (re)connect
        catchUp();
        _flushOutbox();
      }
    });

    _eventsSub = client.incomingEvents.listen((envelope) {
      _onWsEnvelope(envelope);
    });
  }

  void _resetReadPointersFromConversations() {
    final convs = ref.read(conversationsNotifierProvider).asData?.value ?? [];
    final convIndex = convs.indexWhere((c) => c.id == conversationId);
    if (convIndex >= 0) {
      final conv = convs[convIndex];
      final currentUserId = ref.read(authNotifierProvider).user?.id ?? '';
      _lastReadAckSent = conv.myReadSeq(currentUserId);
      state = state.copyWith(
        otherDeliveredSeq: math.max(
          state.otherDeliveredSeq,
          conv.otherDeliveredSeq,
        ),
        otherReadSeq: math.max(state.otherReadSeq, conv.otherReadSeq),
      );
    }
  }

  void _mergeOtherPointersFromConversations() {
    final convs = ref.read(conversationsNotifierProvider).asData?.value ?? [];
    final convIndex = convs.indexWhere((c) => c.id == conversationId);
    if (convIndex >= 0) {
      final conv = convs[convIndex];
      state = state.copyWith(
        otherDeliveredSeq: math.max(
          state.otherDeliveredSeq,
          conv.otherDeliveredSeq,
        ),
        otherReadSeq: math.max(state.otherReadSeq, conv.otherReadSeq),
      );
    }
  }

  void _cancelSubscriptions() {
    _eventsSub?.cancel();
    _eventsSub = null;
    _wsStateSub?.cancel();
    _wsStateSub = null;
    _rateLimitRetryTimer?.cancel();
    _rateLimitRetryTimer = null;
    _readAckTimer?.cancel();
    _readAckTimer = null;
    for (final timer in _typingTimers.values) {
      timer.cancel();
    }
    _typingTimers.clear();
  }

  void _onWsEnvelope(WsEnvelope envelope) {
    if (state.isCatchingUp) {
      // Buffer live events during catch-up (Amendment 7)
      if (envelope.type == 'chat.receive' ||
          envelope.type == 'chat.ack' ||
          envelope.type == 'chat.status') {
        _liveEventBuffer.add(envelope);
        return;
      }
    }

    switch (envelope.type) {
      case 'chat.ack':
        _handleAck(envelope);
        break;
      case 'chat.receive':
        _handleReceive(envelope);
        break;
      case 'chat.status':
        _handleStatus(envelope);
        break;
      case 'chat.typing':
        _handleTyping(envelope);
        break;
      case 'membership.removed':
        _handleMembershipRemoved(envelope);
        break;
      case 'error':
        _handleError(envelope);
        break;
    }
  }

  void _handleStatus(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    if (convId != conversationId) return;

    final userId = payload['user_id'] as String?;
    final currentUserId = ref.read(authNotifierProvider).user?.id ?? '';

    if (userId != currentUserId) {
      final dSeq = (payload['delivered_seq'] as num?)?.toInt() ?? 0;
      final rSeq = (payload['read_seq'] as num?)?.toInt() ?? 0;
      state = state.copyWith(
        otherDeliveredSeq: math.max(state.otherDeliveredSeq, dSeq),
        otherReadSeq: math.max(state.otherReadSeq, rSeq),
      );
    }
  }

  void markReadIfNeeded({
    required bool isForegrounded,
    required bool isNearBottom,
  }) {
    if (!isForegrounded || !isNearBottom) return;

    final currentUserId = ref.read(authNotifierProvider).user?.id ?? '';
    int highestIncomingSeq = 0;
    for (final msg in state.messages) {
      if (msg.senderId != currentUserId &&
          msg.isSent &&
          msg.seq > highestIncomingSeq) {
        highestIncomingSeq = msg.seq;
      }
    }

    if (highestIncomingSeq <= _lastReadAckSent) return;

    _readAckTimer?.cancel();
    _readAckTimer = Timer(const Duration(milliseconds: 300), () {
      if (highestIncomingSeq <= _lastReadAckSent) return;

      final client = ref.read(chatWebSocketClientProvider);
      if (client.state == WebSocketConnectionState.connected) {
        final sent = client.sendEnvelope(
          WsEnvelope(
            type: 'chat.read',
            clientId: _uuid.v4(),
            payload: {
              'conversation_id': conversationId,
              'seq': highestIncomingSeq,
            },
          ),
        );
        if (sent) {
          _lastReadAckSent =
              highestIncomingSeq; // Set ONLY when frame is actually sent
        }
      }
    });
  }

  void cancelReadTimer() {
    _readAckTimer?.cancel();
    _readAckTimer = null;
  }

  void _handleAck(WsEnvelope envelope) {
    final payload = envelope.payload;
    final clientId = envelope.clientId ?? payload['client_id'] as String?;
    final messageId = payload['message_id'] as String?;
    final seq = (payload['seq'] as num?)?.toInt();

    if (clientId == null) return;

    _outbox.removeWhere((msg) => msg.clientId == clientId);

    final current = List<ChatMessage>.from(state.messages);
    final index = current.indexWhere((m) => m.clientId == clientId);

    if (index >= 0) {
      final old = current[index];
      current[index] = old.copyWith(
        id: messageId ?? old.id,
        seq: seq ?? old.seq,
        status: MessageStatus.sent,
        errorMessage: null,
      );
      state = state.copyWith(messages: _sortMessages(current));
    }
  }

  void _handleReceive(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    if (convId != conversationId) return;

    final clientId = envelope.clientId ?? payload['client_id'] as String?;
    final incoming = ChatMessage.fromJson(payload);

    final current = List<ChatMessage>.from(state.messages);

    // 1. Match by client_id first (Amendment 5)
    if (clientId != null && clientId.isNotEmpty) {
      final clientIndex = current.indexWhere((m) => m.clientId == clientId);
      if (clientIndex >= 0) {
        _outbox.removeWhere((m) => m.clientId == clientId);
        current[clientIndex] = incoming.copyWith(
          clientId: clientId,
          status: MessageStatus.sent,
          errorMessage: null,
        );
        state = state.copyWith(messages: _sortMessages(current));
        return;
      }
    }

    // 2. Match by message id
    final idIndex = current.indexWhere((m) => m.id == incoming.id);
    if (idIndex >= 0) {
      // Duplicate echo, ignore
      return;
    }

    // 3. Gap detection (Amendment 7)
    final highestSeq = _getHighestConfirmedSeq(current);
    if (highestSeq > 0 && incoming.seq > highestSeq + 1) {
      current.add(incoming);
      state = state.copyWith(messages: _sortMessages(current));
      _catchUpFrom(highestSeq);
      return;
    }

    // 4. New message
    current.add(incoming);
    state = state.copyWith(messages: _sortMessages(current));
  }

  void _handleError(WsEnvelope envelope) {
    final payload = envelope.payload;
    final clientId = envelope.clientId ?? payload['client_id'] as String?;
    final code = (payload['code'] as num?)?.toInt();
    final message = payload['message'] as String? ?? 'Server error';

    if (clientId == null) return;

    if (code == 429) {
      // Rate limit during flush: schedule retry rather than permanently failing (Amendment 6)
      _rateLimitRetryTimer?.cancel();
      _rateLimitRetryTimer = Timer(const Duration(seconds: 2), () {
        _flushOutbox();
      });
      return;
    }

    if (code == 403 || message.toLowerCase().contains('not a member')) {
      // User was removed or is not a member (Amendment 6)
      _outbox.clear();
      _rateLimitRetryTimer?.cancel();
      state = state.copyWith(isRemovedFromGroup: true);
    }

    // Permanently fail message for client-side action
    _outbox.removeWhere((m) => m.clientId == clientId);
    final current = List<ChatMessage>.from(state.messages);
    final index = current.indexWhere((m) => m.clientId == clientId);
    if (index >= 0) {
      current[index] = current[index].copyWith(
        status: MessageStatus.failed,
        errorMessage: message,
      );
      state = state.copyWith(messages: current);
    }
  }

  void _handleTyping(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    final userId = payload['user_id'] as String?;
    final isTyping = payload['is_typing'] as bool? ?? false;
    final displayName = (payload['display_name'] as String?)?.trim();
    final username = (payload['username'] as String?)?.trim();
    final nameToUse = (displayName != null && displayName.isNotEmpty)
        ? displayName
        : (username != null && username.isNotEmpty ? username : 'Someone');

    if (convId != conversationId || userId == null) return;

    final currentUserId = ref.read(authNotifierProvider).user?.id ?? '';
    if (userId == currentUserId) return;

    final newTyping = Map<String, String>.from(state.typingUsers);

    if (isTyping) {
      newTyping[userId] = nameToUse;
      _typingTimers[userId]?.cancel();
      _typingTimers[userId] = Timer(const Duration(seconds: 5), () {
        final currentMap = Map<String, String>.from(state.typingUsers);
        currentMap.remove(userId);
        _typingTimers.remove(userId);
        state = state.copyWith(typingUsers: currentMap);
      });
    } else {
      newTyping.remove(userId);
      _typingTimers[userId]?.cancel();
      _typingTimers.remove(userId);
    }

    state = state.copyWith(typingUsers: newTyping);
  }

  void _handleMembershipRemoved(WsEnvelope envelope) {
    final payload = envelope.payload;
    final convId = payload['conversation_id'] as String?;
    final userId = payload['user_id'] as String?;
    if (convId != conversationId || userId == null) return;

    final currentUserId = ref.read(authNotifierProvider).user?.id ?? '';
    if (userId == currentUserId) {
      // Current user removed from group (Amendment 6)
      _outbox.clear();
      _rateLimitRetryTimer?.cancel();
      state = state.copyWith(isRemovedFromGroup: true);
    }
  }

  void sendTyping(bool isTyping) {
    if (state.isRemovedFromGroup) return;
    final client = ref.read(chatWebSocketClientProvider);
    if (client.state == WebSocketConnectionState.connected) {
      client.sendEnvelope(
        WsEnvelope(
          type: 'chat.typing',
          clientId: _uuid.v4(),
          payload: {'conversation_id': conversationId, 'is_typing': isTyping},
        ),
      );
    }
  }

  Future<void> loadInitial() async {
    try {
      _resetReadPointersFromConversations();
      final repository = ref.read(chatRepositoryProvider);
      final messages = await repository.getMessages(conversationId, limit: 30);
      final hasMore = messages.length >= 30;

      // Merge with any current pending messages
      final pending = state.messages.where((m) => m.isPending || m.isFailed);
      final combined = [...messages, ...pending];

      state = state.copyWith(
        messages: _sortMessages(combined),
        isLoading: false,
        hasMoreOlder: hasMore,
        error: null,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadOlder() async {
    if (state.isLoadingOlder || !state.hasMoreOlder) return;

    state = state.copyWith(isLoadingOlder: true);

    final lowestSeq = _getLowestConfirmedSeq(state.messages);
    if (lowestSeq <= 1) {
      state = state.copyWith(isLoadingOlder: false, hasMoreOlder: false);
      return;
    }

    try {
      final repository = ref.read(chatRepositoryProvider);
      final older = await repository.getMessages(
        conversationId,
        beforeSeq: lowestSeq,
        limit: 30,
      );

      final hasMore = older.length >= 30;
      final current = List<ChatMessage>.from(state.messages);

      // Prepend older messages not already in list
      final existingIds = current.map((m) => m.id).toSet();
      for (final msg in older.reversed) {
        if (!existingIds.contains(msg.id)) {
          current.insert(0, msg);
        }
      }

      state = state.copyWith(
        messages: _sortMessages(current),
        isLoadingOlder: false,
        hasMoreOlder: hasMore,
      );
    } catch (e) {
      state = state.copyWith(isLoadingOlder: false, error: e.toString());
    }
  }

  Future<void> _catchUpFrom(int fromSeq) => catchUp(fromSeq: fromSeq);

  /// Catch-up sync: fetches after_seq in a loop until a short page (< 100),
  /// buffering live events during fetch and applying them afterward (Amendment 7).
  Future<void> catchUp({int? fromSeq}) async {
    if (state.isCatchingUp) return;

    state = state.copyWith(isCatchingUp: true);
    _liveEventBuffer.clear();

    try {
      final repository = ref.read(chatRepositoryProvider);
      int highestSeq = fromSeq ?? _getHighestConfirmedSeq(state.messages);
      bool hasMorePages = true;

      while (hasMorePages) {
        final page = await repository.getMessages(
          conversationId,
          afterSeq: highestSeq,
          limit: 100,
        );

        if (page.isEmpty) {
          hasMorePages = false;
          break;
        }

        final current = List<ChatMessage>.from(state.messages);
        final existingIds = current.map((m) => m.id).toSet();

        for (final msg in page) {
          if (existingIds.contains(msg.id)) continue;

          final pendingIndex = current.indexWhere(
            (m) => m.clientId.isNotEmpty && m.clientId == msg.clientId,
          );
          if (pendingIndex >= 0) {
            _outbox.removeWhere((m) => m.clientId == msg.clientId);
            current[pendingIndex] = msg;
          } else {
            current.add(msg);
          }
          if (msg.seq > highestSeq) {
            highestSeq = msg.seq;
          }
        }

        state = state.copyWith(messages: _sortMessages(current));
        hasMorePages = page.length == 100;
      }
    } catch (_) {
      // Ignored; live socket will continue to deliver
    } finally {
      state = state.copyWith(isCatchingUp: false);
      // Process buffered events
      final buffered = List<WsEnvelope>.from(_liveEventBuffer);
      _liveEventBuffer.clear();
      for (final event in buffered) {
        _onWsEnvelope(event);
      }
    }
  }

  /// Sends a message optimistically and queues to outbox.
  Future<void> sendMessage(String text) async {
    if (state.isRemovedFromGroup) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 4000) return;

    final authState = ref.read(authNotifierProvider);
    final currentUserId = authState.user?.id ?? '';
    final clientId = _uuid.v4();

    final pendingMessage = ChatMessage(
      id: clientId,
      conversationId: conversationId,
      senderId: currentUserId,
      seq: -1,
      body: trimmed,
      clientId: clientId,
      createdAt: DateTime.now().toUtc(),
      status: MessageStatus.pending,
    );

    _outbox.add(pendingMessage);
    final updated = [...state.messages, pendingMessage];
    state = state.copyWith(messages: updated);

    final client = ref.read(chatWebSocketClientProvider);
    if (client.state == WebSocketConnectionState.connected) {
      client.sendEnvelope(
        WsEnvelope(
          type: 'chat.send',
          clientId: clientId,
          payload: {'conversation_id': conversationId, 'body': trimmed},
        ),
      );
    }
  }

  /// Retries sending a failed message using the EXACT same client_id (Amendment 6).
  void retryMessage(String clientId) {
    final current = List<ChatMessage>.from(state.messages);
    final index = current.indexWhere((m) => m.clientId == clientId);
    if (index == -1) return;

    final msg = current[index];
    final updated = msg.copyWith(
      status: MessageStatus.pending,
      errorMessage: null,
    );
    current[index] = updated;
    state = state.copyWith(messages: current);

    if (!_outbox.any((m) => m.clientId == clientId)) {
      _outbox.add(updated);
    }

    final client = ref.read(chatWebSocketClientProvider);
    if (client.state == WebSocketConnectionState.connected) {
      client.sendEnvelope(
        WsEnvelope(
          type: 'chat.send',
          clientId: clientId,
          payload: {'conversation_id': conversationId, 'body': msg.body},
        ),
      );
    }
  }

  Future<void> _flushOutbox() async {
    if (_isFlushingOutbox || _outbox.isEmpty) return;
    _isFlushingOutbox = true;

    final client = ref.read(chatWebSocketClientProvider);
    final pendingSnapshot = List<ChatMessage>.from(_outbox);

    for (final msg in pendingSnapshot) {
      if (client.state != WebSocketConnectionState.connected) break;
      // Skip if message was already acked or removed from outbox
      if (!_outbox.any((m) => m.clientId == msg.clientId)) continue;

      final sent = client.sendEnvelope(
        WsEnvelope(
          type: 'chat.send',
          clientId: msg.clientId,
          payload: {'conversation_id': msg.conversationId, 'body': msg.body},
        ),
      );

      if (!sent) break;

      // Pace sends by 550ms so flush stays strictly under 20 sends / 10s
      await Future.delayed(const Duration(milliseconds: 550));
    }

    _isFlushingOutbox = false;
  }

  List<ChatMessage> _sortMessages(List<ChatMessage> list) {
    final confirmed = list.where((m) => m.isSent).toList()
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final pending = list.where((m) => !m.isSent).toList();
    return [...confirmed, ...pending];
  }

  int _getHighestConfirmedSeq(List<ChatMessage> list) {
    int maxSeq = 0;
    for (final m in list) {
      if (m.isSent && m.seq > maxSeq) {
        maxSeq = m.seq;
      }
    }
    return maxSeq;
  }

  int _getLowestConfirmedSeq(List<ChatMessage> list) {
    int minSeq = 999999999;
    bool found = false;
    for (final m in list) {
      if (m.isSent) {
        found = true;
        if (m.seq < minSeq) {
          minSeq = m.seq;
        }
      }
    }
    return found ? minSeq : 0;
  }
}

final chatMessagesNotifierProvider =
    NotifierProvider.family<ChatNotifier, ChatMessagesState, String>(
      (arg) => ChatNotifier(arg),
    );
