import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pixel_chat/core/network/websocket_client.dart';
import 'package:pixel_chat/features/auth/application/auth_notifier.dart';
import 'package:pixel_chat/features/auth/application/auth_state.dart';
import 'package:pixel_chat/features/auth/domain/user.dart';
import 'package:pixel_chat/features/chat/application/chat_notifier.dart';
import 'package:pixel_chat/features/chat/application/conversations_notifier.dart';
import 'package:pixel_chat/features/chat/application/websocket_provider.dart';
import 'package:pixel_chat/features/chat/data/chat_repository.dart';
import 'package:pixel_chat/features/chat/domain/chat_models.dart';

class MockChatRepository extends Mock implements ChatRepository {}

class MockChatWebSocketClient extends Mock implements ChatWebSocketClient {}

class FakeWsEnvelope extends Fake implements WsEnvelope {}

class FakeAuthNotifier extends AuthNotifier {
  FakeAuthNotifier(this._initialState);
  final AuthState _initialState;

  @override
  AuthState build() => _initialState;

  void setUnauthenticated() {
    state = const AuthState.unauthenticated();
  }

  @override
  Future<void> retryBootstrap() async {}

  @override
  Future<void> login({required String email, required String password}) async {}

  @override
  Future<void> register({
    required String email,
    required String username,
    required String displayName,
    required String password,
    String? inviteCode,
  }) async {}

  @override
  Future<void> logout() async {
    state = const AuthState.unauthenticated();
  }

  @override
  void onSessionExpired() {
    state = const AuthState.unauthenticated();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeWsEnvelope());
  });

  late MockChatRepository mockRepo;
  late MockChatWebSocketClient mockWsClient;
  late StreamController<WsEnvelope> wsEventsController;
  late StreamController<WebSocketConnectionState> wsStateController;

  const testConvId = 'conv-123';
  final testUser = User(
    id: 'user-me',
    username: 'me',
    displayName: 'Me',
    avatarSeed: 'seed',
    createdAt: DateTime.now().toUtc(),
  );

  setUp(() {
    mockRepo = MockChatRepository();
    mockWsClient = MockChatWebSocketClient();
    wsEventsController = StreamController<WsEnvelope>.broadcast();
    wsStateController = StreamController<WebSocketConnectionState>.broadcast();

    when(
      () => mockWsClient.incomingEvents,
    ).thenAnswer((_) => wsEventsController.stream);
    when(
      () => mockWsClient.stateStream,
    ).thenAnswer((_) => wsStateController.stream);
    when(
      () => mockWsClient.state,
    ).thenReturn(WebSocketConnectionState.connected);
    when(() => mockWsClient.sendEnvelope(any())).thenReturn(true);

    when(
      () => mockRepo.getMessages(testConvId, limit: any(named: 'limit')),
    ).thenAnswer((_) async => []);
  });

  tearDown(() {
    wsEventsController.close();
    wsStateController.close();
  });

  ProviderContainer createContainer({
    AuthState? authState,
    FakeAuthNotifier? fakeAuthNotifier,
  }) {
    final auth = authState ?? AuthState.authenticated(testUser);
    final notifierInstance = fakeAuthNotifier ?? FakeAuthNotifier(auth);

    final container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepo),
        chatWebSocketClientProvider.overrideWithValue(mockWsClient),
        authNotifierProvider.overrideWith(() => notifierInstance),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'optimistic pending message immediately appears in state and outbox',
    () async {
      final container = createContainer();
      final notifier = container.read(
        chatMessagesNotifierProvider(testConvId).notifier,
      );
      await pumpEventQueue();

      await notifier.sendMessage('Hello world');

      final state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.messages.length, 1);
      final msg = state.messages.first;
      expect(msg.body, 'Hello world');
      expect(msg.isPending, true);
      expect(msg.clientId, isNotEmpty);

      verify(
        () => mockWsClient.sendEnvelope(
          any(
            that: isA<WsEnvelope>()
                .having((e) => e.type, 'type', 'chat.send')
                .having((e) => e.clientId, 'clientId', msg.clientId),
          ),
        ),
      ).called(1);
    },
  );

  test(
    'ack transitions message from pending to sent with confirmed seq and message_id',
    () async {
      final container = createContainer();
      final notifier = container.read(
        chatMessagesNotifierProvider(testConvId).notifier,
      );
      await pumpEventQueue();

      await notifier.sendMessage('Hello world');
      final clientId = container
          .read(chatMessagesNotifierProvider(testConvId))
          .messages
          .first
          .clientId;

      // Simulate chat.ack
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.ack',
          clientId: clientId,
          payload: {
            'client_id': clientId,
            'message_id': 'server-msg-1',
            'seq': 42,
          },
        ),
      );
      await pumpEventQueue();

      final state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.messages.length, 1);
      final msg = state.messages.first;
      expect(msg.id, 'server-msg-1');
      expect(msg.seq, 42);
      expect(msg.status, MessageStatus.sent);
    },
  );

  test('ack then echo deduplicates into exactly one message', () async {
    final container = createContainer();
    final notifier = container.read(
      chatMessagesNotifierProvider(testConvId).notifier,
    );
    await pumpEventQueue();

    await notifier.sendMessage('Hello world');
    final clientId = container
        .read(chatMessagesNotifierProvider(testConvId))
        .messages
        .first
        .clientId;

    // 1. Ack arrives first
    wsEventsController.add(
      WsEnvelope(
        type: 'chat.ack',
        clientId: clientId,
        payload: {'client_id': clientId, 'message_id': 'msg-99', 'seq': 10},
      ),
    );
    await pumpEventQueue();

    // 2. Echo arrives second
    wsEventsController.add(
      WsEnvelope(
        type: 'chat.receive',
        clientId: clientId,
        payload: {
          'id': 'msg-99',
          'conversation_id': testConvId,
          'sender_id': 'user-me',
          'seq': 10,
          'body': 'Hello world',
          'client_id': clientId,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    await pumpEventQueue();

    final state = container.read(chatMessagesNotifierProvider(testConvId));
    expect(state.messages.length, 1);
    expect(state.messages.first.id, 'msg-99');
    expect(state.messages.first.isSent, true);
  });

  test('echo then ack deduplicates into exactly one message', () async {
    final container = createContainer();
    final notifier = container.read(
      chatMessagesNotifierProvider(testConvId).notifier,
    );
    await pumpEventQueue();

    await notifier.sendMessage('Hello world');
    final clientId = container
        .read(chatMessagesNotifierProvider(testConvId))
        .messages
        .first
        .clientId;

    // 1. Echo arrives first
    wsEventsController.add(
      WsEnvelope(
        type: 'chat.receive',
        clientId: clientId,
        payload: {
          'id': 'msg-99',
          'conversation_id': testConvId,
          'sender_id': 'user-me',
          'seq': 10,
          'body': 'Hello world',
          'client_id': clientId,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      ),
    );
    await pumpEventQueue();

    // 2. Ack arrives second
    wsEventsController.add(
      WsEnvelope(
        type: 'chat.ack',
        clientId: clientId,
        payload: {'client_id': clientId, 'message_id': 'msg-99', 'seq': 10},
      ),
    );
    await pumpEventQueue();

    final state = container.read(chatMessagesNotifierProvider(testConvId));
    expect(state.messages.length, 1);
    expect(state.messages.first.id, 'msg-99');
    expect(state.messages.first.isSent, true);
  });

  test(
    'gap detection: incoming.seq > highestSeq + 1 triggers catchUp',
    () async {
      when(
        () => mockRepo.getMessages(testConvId, limit: any(named: 'limit')),
      ).thenAnswer(
        (_) async => [
          ChatMessage(
            id: 'm1',
            conversationId: testConvId,
            senderId: 'other',
            seq: 5,
            body: 'Five',
            clientId: 'c1',
            createdAt: DateTime.now().toUtc(),
            status: MessageStatus.sent,
          ),
        ],
      );

      final container = createContainer();
      container.read(chatMessagesNotifierProvider(testConvId));
      await pumpEventQueue();

      // Mock catch-up returning seq 6 and 7
      when(
        () => mockRepo.getMessages(testConvId, afterSeq: 5, limit: 100),
      ).thenAnswer(
        (_) async => [
          ChatMessage(
            id: 'm2',
            conversationId: testConvId,
            senderId: 'other',
            seq: 6,
            body: 'Six',
            clientId: 'c2',
            createdAt: DateTime.now().toUtc(),
            status: MessageStatus.sent,
          ),
          ChatMessage(
            id: 'm3',
            conversationId: testConvId,
            senderId: 'other',
            seq: 7,
            body: 'Seven',
            clientId: 'c3',
            createdAt: DateTime.now().toUtc(),
            status: MessageStatus.sent,
          ),
        ],
      );

      // Live message seq 8 arrives (gap: 8 > 5 + 1)
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm4',
            'conversation_id': testConvId,
            'sender_id': 'other',
            'seq': 8,
            'body': 'Eight',
            'client_id': 'c4',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          },
        ),
      );
      await pumpEventQueue();

      verify(
        () => mockRepo.getMessages(testConvId, afterSeq: 5, limit: 100),
      ).called(1);

      final state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.messages.map((m) => m.seq).toList(), [5, 6, 7, 8]);
    },
  );

  test('catch-up loops over multiple pages (limit: 100)', () async {
    final page1 = List.generate(
      100,
      (i) => ChatMessage(
        id: 'msg-$i',
        conversationId: testConvId,
        senderId: 'other',
        seq: i + 1,
        body: 'Message $i',
        clientId: 'c-$i',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      ),
    );
    final page2 = [
      ChatMessage(
        id: 'msg-101',
        conversationId: testConvId,
        senderId: 'other',
        seq: 101,
        body: 'Message 101',
        clientId: 'c-101',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      ),
    ];

    when(
      () => mockRepo.getMessages(testConvId, afterSeq: 0, limit: 100),
    ).thenAnswer((_) async => page1);
    when(
      () => mockRepo.getMessages(testConvId, afterSeq: 100, limit: 100),
    ).thenAnswer((_) async => page2);

    final container = createContainer();
    final notifier = container.read(
      chatMessagesNotifierProvider(testConvId).notifier,
    );
    await pumpEventQueue();

    await notifier.catchUp();
    await pumpEventQueue();

    verify(
      () => mockRepo.getMessages(testConvId, afterSeq: 0, limit: 100),
    ).called(1);
    verify(
      () => mockRepo.getMessages(testConvId, afterSeq: 100, limit: 100),
    ).called(1);

    final state = container.read(chatMessagesNotifierProvider(testConvId));
    expect(state.messages.length, 101);
  });

  test(
    'server error (400) marks message failed with error message for retry',
    () async {
      final container = createContainer();
      final notifier = container.read(
        chatMessagesNotifierProvider(testConvId).notifier,
      );
      await pumpEventQueue();

      await notifier.sendMessage('Bad message');
      final clientId = container
          .read(chatMessagesNotifierProvider(testConvId))
          .messages
          .first
          .clientId;

      wsEventsController.add(
        WsEnvelope(
          type: 'error',
          clientId: clientId,
          payload: {
            'client_id': clientId,
            'code': 400,
            'message': 'Message body cannot be empty',
          },
        ),
      );
      await pumpEventQueue();

      final state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.messages.first.isFailed, true);
      expect(state.messages.first.errorMessage, 'Message body cannot be empty');
    },
  );

  test(
    'on every reconnect, all still-pending messages are resent in order with SAME client_id',
    () async {
      final container = createContainer();
      final notifier = container.read(
        chatMessagesNotifierProvider(testConvId).notifier,
      );
      await pumpEventQueue();

      // Send 2 messages while connected
      await notifier.sendMessage('Message 1');
      await notifier.sendMessage('Message 2');

      final stateBefore = container.read(
        chatMessagesNotifierProvider(testConvId),
      );
      expect(stateBefore.messages.length, 2);
      final id1 = stateBefore.messages[0].clientId;
      final id2 = stateBefore.messages[1].clientId;

      // Clear invocations from initial send
      clearInteractions(mockWsClient);

      // Simulate WebSocket disconnect and then reconnect
      wsStateController.add(WebSocketConnectionState.waitingToRetry);
      await pumpEventQueue();

      final sentEnvelopes = <WsEnvelope>[];
      when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
        sentEnvelopes.add(invocation.positionalArguments[0] as WsEnvelope);
        return true;
      });

      wsStateController.add(WebSocketConnectionState.connected);
      // Allow timer / outbox flush delays to run
      await pumpEventQueue();
      await Future.delayed(const Duration(milliseconds: 1200));
      await pumpEventQueue();

      // Verify both pending messages were resent with their exact original client_ids in order
      expect(sentEnvelopes.length, greaterThanOrEqualTo(2));
      expect(sentEnvelopes[0].clientId, id1);
      expect(sentEnvelopes[0].payload['body'], 'Message 1');
      expect(sentEnvelopes[1].clientId, id2);
      expect(sentEnvelopes[1].payload['body'], 'Message 2');
    },
  );

  test('concurrent older-page loads are prevented', () async {
    final completer = Completer<List<ChatMessage>>();
    when(
      () => mockRepo.getMessages(
        testConvId,
        beforeSeq: any(named: 'beforeSeq'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) => completer.future);

    // Seed state with 30 messages so hasMoreOlder is true and lowestSeq > 1
    final initialPage = List.generate(
      30,
      (i) => ChatMessage(
        id: 'm-${i + 10}',
        conversationId: testConvId,
        senderId: 'user-other',
        seq: i + 10,
        body: 'Message ${i + 10}',
        clientId: 'c-${i + 10}',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      ),
    );
    when(
      () => mockRepo.getMessages(testConvId, limit: 30),
    ).thenAnswer((_) async => initialPage);

    final container = createContainer();
    final notifier = container.read(
      chatMessagesNotifierProvider(testConvId).notifier,
    );
    await pumpEventQueue();

    // Fire first loadOlder call
    final future1 = notifier.loadOlder();
    // Immediately fire second loadOlder call while first is in-flight
    final future2 = notifier.loadOlder();

    // Complete the in-flight request
    completer.complete([]);
    await Future.wait([future1, future2]);
    await pumpEventQueue();

    // Only 1 call made for older messages (plus the initial load of 30)
    verify(
      () => mockRepo.getMessages(testConvId, beforeSeq: 10, limit: 30),
    ).called(1);
  });

  test('logout clears messages and outbox state', () async {
    final fakeAuthNotifier = FakeAuthNotifier(
      AuthState.authenticated(testUser),
    );
    final container = createContainer(fakeAuthNotifier: fakeAuthNotifier);
    final notifier = container.read(
      chatMessagesNotifierProvider(testConvId).notifier,
    );
    await pumpEventQueue();

    await notifier.sendMessage('Test');
    expect(
      container.read(chatMessagesNotifierProvider(testConvId)).messages.length,
      1,
    );

    // Simulate logout
    fakeAuthNotifier.setUnauthenticated();
    await pumpEventQueue();

    final state = container.read(chatMessagesNotifierProvider(testConvId));
    expect(state.messages.isEmpty, true);
  });
}
