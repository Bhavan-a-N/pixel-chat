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
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeWsEnvelope());
  });

  late MockChatRepository mockRepo;
  late MockChatWebSocketClient mockWsClient;
  late StreamController<WebSocketConnectionState> wsStateController;
  late StreamController<WsEnvelope> wsEventsController;
  late ProviderContainer container;

  final currentUser = User(
    id: 'user-me',
    username: 'alice',
    displayName: 'Alice',
    avatarSeed: 'seed',
    createdAt: DateTime.now().toUtc(),
  );

  const testConvId = 'conv-123';

  setUp(() {
    mockRepo = MockChatRepository();
    mockWsClient = MockChatWebSocketClient();
    wsStateController = StreamController<WebSocketConnectionState>.broadcast();
    wsEventsController = StreamController<WsEnvelope>.broadcast();

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
  });

  tearDown(() {
    container.dispose();
    wsStateController.close();
    wsEventsController.close();
  });

  void setupContainer({
    List<ChatMessage>? messages,
    List<Conversation>? convs,
  }) {
    when(
      () => mockRepo.getMessages(testConvId, limit: any(named: 'limit')),
    ).thenAnswer((_) async => messages ?? []);
    when(
      () => mockRepo.getConversations(),
    ).thenAnswer((_) async => convs ?? []);

    container = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepo),
        chatWebSocketClientProvider.overrideWithValue(mockWsClient),
        authNotifierProvider.overrideWith(
          () => FakeAuthNotifier(AuthState.authenticated(currentUser)),
        ),
      ],
    );
  }

  test(
    'Read acks debounced ~300ms only when foregrounded and at bottom',
    () async {
      final incomingMsg = ChatMessage(
        id: 'm1',
        conversationId: testConvId,
        senderId: 'user-bob',
        seq: 4,
        body: 'Hello',
        clientId: 'b1',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      );

      setupContainer(messages: [incomingMsg]);
      final notifier = container.read(
        chatMessagesNotifierProvider(testConvId).notifier,
      );
      await Future<void>.delayed(Duration.zero);

      final sentEnvelopes = <WsEnvelope>[];
      when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
        final env = invocation.positionalArguments[0] as WsEnvelope;
        sentEnvelopes.add(env);
        return true;
      });

      // 1. When backgrounded or scrolled up: no read ack
      notifier.markReadIfNeeded(isForegrounded: false, isNearBottom: true);
      notifier.markReadIfNeeded(isForegrounded: true, isNearBottom: false);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(sentEnvelopes.where((e) => e.type == 'chat.read'), isEmpty);

      // 2. When foregrounded and at bottom: debounced read ack sent after 300ms
      notifier.markReadIfNeeded(isForegrounded: true, isNearBottom: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sentEnvelopes.where((e) => e.type == 'chat.read'), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      final readEnvs = sentEnvelopes
          .where((e) => e.type == 'chat.read')
          .toList();
      expect(readEnvs.length, 1);
      expect(readEnvs.first.payload['conversation_id'], testConvId);
      expect(readEnvs.first.payload['seq'], 4);
    },
  );

  test('Read ack never fires for own messages', () async {
    final myMsg = ChatMessage(
      id: 'm-me',
      conversationId: testConvId,
      senderId: 'user-me',
      seq: 7,
      body: 'My message',
      clientId: 'me-1',
      createdAt: DateTime.now().toUtc(),
      status: MessageStatus.sent,
    );

    setupContainer(messages: [myMsg]);
    final notifier = container.read(
      chatMessagesNotifierProvider(testConvId).notifier,
    );
    await Future<void>.delayed(Duration.zero);

    final sentEnvelopes = <WsEnvelope>[];
    when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
      final env = invocation.positionalArguments[0] as WsEnvelope;
      sentEnvelopes.add(env);
      return true;
    });

    notifier.markReadIfNeeded(isForegrounded: true, isNearBottom: true);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(sentEnvelopes.where((e) => e.type == 'chat.read'), isEmpty);
  });

  test(
    'chat.status updates otherDeliveredSeq and otherReadSeq monotonically',
    () async {
      setupContainer();
      container.read(chatMessagesNotifierProvider(testConvId));
      await Future<void>.delayed(Duration.zero);

      // Live status from Bob
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.status',
          payload: {
            'conversation_id': testConvId,
            'user_id': 'user-bob',
            'delivered_seq': 8,
            'read_seq': 5,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.otherDeliveredSeq, 8);
      expect(state.otherReadSeq, 5);

      // Stale status event does not decrement pointers
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.status',
          payload: {
            'conversation_id': testConvId,
            'user_id': 'user-bob',
            'delivered_seq': 7,
            'read_seq': 4,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.otherDeliveredSeq, 8);
      expect(state.otherReadSeq, 5);
    },
  );

  test(
    'Ack-tracking reset (read ack): resets tracking to REST pointer on reconnect and resends ack, does not advance tracking when socket down',
    () async {
      final msg10 = ChatMessage(
        id: 'm10',
        conversationId: testConvId,
        senderId: 'user-bob',
        seq: 10,
        body: 'Hello 10',
        clientId: 'b10',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      );

      final initialConv = Conversation(
        id: testConvId,
        type: 'dm',
        lastSeq: 10,
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 10,
            lastReadSeq: 2,
          ),
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 10,
            lastReadSeq: 10,
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      setupContainer(messages: [msg10], convs: [initialConv]);
      final notifier = container.read(
        chatMessagesNotifierProvider(testConvId).notifier,
      );
      container.read(conversationsNotifierProvider);
      await Future<void>.delayed(Duration.zero);

      final sentEnvelopes = <WsEnvelope>[];
      when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
        final env = invocation.positionalArguments[0] as WsEnvelope;
        sentEnvelopes.add(env);
        return true;
      });

      // 1. Send read ack for seq 10
      notifier.markReadIfNeeded(isForegrounded: true, isNearBottom: true);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        sentEnvelopes
            .where((e) => e.type == 'chat.read' && e.payload['seq'] == 10)
            .length,
        1,
      );
      expect(notifier.lastReadAckSent, 10);

      // 2. Drop the socket
      when(
        () => mockWsClient.state,
      ).thenReturn(WebSocketConnectionState.waitingToRetry);
      wsStateController.add(WebSocketConnectionState.waitingToRetry);
      await Future<void>.delayed(Duration.zero);

      // Receive msg12 while socket is down
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm12',
            'conversation_id': testConvId,
            'sender_id': 'user-bob',
            'seq': 12,
            'body': 'Hello 12',
            'client_id': 'b12',
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // Call markReadIfNeeded while socket is down
      notifier.markReadIfNeeded(isForegrounded: true, isNearBottom: true);
      await Future<void>.delayed(const Duration(milliseconds: 350));

      // Assert tracking value is NOT advanced when socket was down at send time
      expect(notifier.lastReadAckSent, 10);

      // 3. Reconnect with a REST payload whose pointers are LOWER than what was tracked (simulating a lost ack)
      final lostAckConv = Conversation(
        id: testConvId,
        type: 'dm',
        lastSeq: 12,
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 10,
            lastReadSeq: 3, // LOWER than tracked (10)
          ),
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 12,
            lastReadSeq: 12,
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      when(
        () => mockRepo.getConversations(),
      ).thenAnswer((_) async => [lostAckConv]);
      sentEnvelopes.clear();

      when(
        () => mockWsClient.state,
      ).thenReturn(WebSocketConnectionState.connected);
      wsStateController.add(WebSocketConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      // Assert tracking value resets to REST pointer (3)
      expect(notifier.lastReadAckSent, 3);

      // And the ack is sent again (debounced after markReadIfNeeded)
      notifier.markReadIfNeeded(isForegrounded: true, isNearBottom: true);
      await Future<void>.delayed(const Duration(milliseconds: 350));

      final resendRead = sentEnvelopes
          .where(
            (e) =>
                e.type == 'chat.read' &&
                e.payload['conversation_id'] == testConvId,
          )
          .toList();
      expect(resendRead.length, 1);
      expect(resendRead.first.payload['seq'], 12);
      expect(notifier.lastReadAckSent, 12);
    },
  );

  test(
    'Older REST payload in ChatNotifier: status event sets delivered=10/read=8, REST payload returns 5/3 -> pointers stay 10/8 and ticks do not regress',
    () async {
      setupContainer();
      container.read(chatMessagesNotifierProvider(testConvId));
      container.read(conversationsNotifierProvider);
      await Future<void>.delayed(Duration.zero);

      // 1. Live status event delivered=10/read=8
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.status',
          payload: {
            'conversation_id': testConvId,
            'user_id': 'user-bob',
            'delivered_seq': 10,
            'read_seq': 8,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(chatMessagesNotifierProvider(testConvId));
      expect(state.otherDeliveredSeq, 10);
      expect(state.otherReadSeq, 8);

      // 2. Hydrate from older REST payload with delivered=5/read=3
      final olderConv = Conversation(
        id: testConvId,
        type: 'dm',
        lastSeq: 5,
        otherDeliveredSeq: 5,
        otherReadSeq: 3,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        memberships: [
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 5,
            lastReadSeq: 3,
          ),
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 5,
            lastReadSeq: 3,
          ),
        ],
      );

      when(
        () => mockRepo.getConversations(),
      ).thenAnswer((_) async => [olderConv]);
      await container.read(conversationsNotifierProvider.notifier).load();

      state = container.read(chatMessagesNotifierProvider(testConvId));

      // Assert pointers stay 10/8
      expect(state.otherDeliveredSeq, 10);
      expect(state.otherReadSeq, 8);

      // Assert ticks don't regress
      final myMsgSeq8 = ChatMessage(
        id: 'm8',
        conversationId: testConvId,
        senderId: 'user-me',
        seq: 8,
        body: 'Message 8',
        clientId: 'me8',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      );
      expect(
        myMsgSeq8.getTickStatus(
          isMe: true,
          otherDeliveredSeq: state.otherDeliveredSeq,
          otherReadSeq: state.otherReadSeq,
        ),
        MessageTickStatus.read,
      );
    },
  );
}
