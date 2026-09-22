import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pixel_chat/core/network/websocket_client.dart';
import 'package:pixel_chat/features/auth/application/auth_notifier.dart';
import 'package:pixel_chat/features/auth/application/auth_state.dart';
import 'package:pixel_chat/features/auth/domain/user.dart';
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

  void setupContainer({List<Conversation>? initialConvs}) {
    when(
      () => mockRepo.getConversations(),
    ).thenAnswer((_) async => initialConvs ?? []);

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
    'Delivered acks batched and debounced (~300ms) for incoming chat.receive when chat is closed',
    () async {
      final conv1 = Conversation(
        id: 'c1',
        type: 'dm',
        lastSeq: 0,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      final conv2 = Conversation(
        id: 'c2',
        type: 'dm',
        lastSeq: 0,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      setupContainer(initialConvs: [conv1, conv2]);
      container.read(conversationsNotifierProvider);
      await Future<void>.delayed(Duration.zero);

      final sentEnvelopes = <WsEnvelope>[];
      when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
        final env = invocation.positionalArguments[0] as WsEnvelope;
        sentEnvelopes.add(env);
        return true;
      });

      // 1. Receive incoming messages for c1 and c2 from other participant
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm1',
            'conversation_id': 'c1',
            'sender_id': 'user-bob',
            'seq': 1,
            'body': 'Hi 1',
            'client_id': 'b1',
          },
        ),
      );
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm2',
            'conversation_id': 'c1',
            'sender_id': 'user-bob',
            'seq': 2,
            'body': 'Hi 2',
            'client_id': 'b2',
          },
        ),
      );
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm3',
            'conversation_id': 'c2',
            'sender_id': 'user-charlie',
            'seq': 5,
            'body': 'Hi 5',
            'client_id': 'c5',
          },
        ),
      );

      // Before debounce duration (100ms), NO delivered frame is sent yet
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sentEnvelopes.where((e) => e.type == 'chat.delivered'), isEmpty);

      // After debounce (~350ms total), batched acks for highest seqs are sent
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final deliveredEnvs = sentEnvelopes
          .where((e) => e.type == 'chat.delivered')
          .toList();

      expect(deliveredEnvs.length, 2);
      final c1Ack = deliveredEnvs.firstWhere(
        (e) => e.payload['conversation_id'] == 'c1',
      );
      final c2Ack = deliveredEnvs.firstWhere(
        (e) => e.payload['conversation_id'] == 'c2',
      );
      expect(c1Ack.payload['seq'], 2); // highest received seq for c1
      expect(c2Ack.payload['seq'], 5); // highest received seq for c2
    },
  );

  test('Delivered acks are NOT sent for own messages', () async {
    final conv1 = Conversation(
      id: 'c1',
      type: 'dm',
      lastSeq: 0,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );

    setupContainer(initialConvs: [conv1]);
    container.read(conversationsNotifierProvider);
    await Future<void>.delayed(Duration.zero);

    final sentEnvelopes = <WsEnvelope>[];
    when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
      sentEnvelopes.add(invocation.positionalArguments[0] as WsEnvelope);
      return true;
    });

    // Receive message sent by me (e.g. echo or another device)
    wsEventsController.add(
      WsEnvelope(
        type: 'chat.receive',
        payload: {
          'id': 'm-me',
          'conversation_id': 'c1',
          'sender_id': 'user-me',
          'seq': 3,
          'body': 'My own message',
          'client_id': 'me-1',
        },
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(sentEnvelopes.where((e) => e.type == 'chat.delivered'), isEmpty);
  });

  test(
    'Reconnect delivered ack: sends one chat.delivered for non-open conversation with incoming message and lastSeq > delivered pointer, nothing for own message or current pointer',
    () async {
      final convIncoming = Conversation(
        id: 'c1',
        type: 'dm',
        lastSeq: 5,
        lastMessage: ChatMessage(
          id: 'm5',
          conversationId: 'c1',
          senderId: 'user-bob',
          seq: 5,
          body: 'Message 5 from Bob',
          clientId: 'cb5',
          createdAt: DateTime.now().toUtc(),
        ),
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 2,
            lastReadSeq: 1,
          ),
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 5,
            lastReadSeq: 5,
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      final convOwnMessage = Conversation(
        id: 'c2',
        type: 'dm',
        lastSeq: 4,
        lastMessage: ChatMessage(
          id: 'm4',
          conversationId: 'c2',
          senderId: 'user-me',
          seq: 4,
          body: 'My message 4',
          clientId: 'me4',
          createdAt: DateTime.now().toUtc(),
        ),
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 2,
            lastReadSeq: 1,
          ),
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 4,
            lastReadSeq: 4,
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      final convCurrentPointer = Conversation(
        id: 'c3',
        type: 'dm',
        lastSeq: 3,
        lastMessage: ChatMessage(
          id: 'm3',
          conversationId: 'c3',
          senderId: 'user-bob',
          seq: 3,
          body: 'Message 3 from Bob',
          clientId: 'cb3',
          createdAt: DateTime.now().toUtc(),
        ),
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 3,
            lastReadSeq: 3,
          ),
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 3,
            lastReadSeq: 3,
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      final convs = [convIncoming, convOwnMessage, convCurrentPointer];
      setupContainer(initialConvs: convs);

      final sentEnvelopes = <WsEnvelope>[];
      when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
        sentEnvelopes.add(invocation.positionalArguments[0] as WsEnvelope);
        return true;
      });

      // Initial load
      container.read(conversationsNotifierProvider);
      await Future<void>.delayed(Duration.zero);

      // Clear envelopes from initial startup
      sentEnvelopes.clear();

      // Simulate socket going disconnected, then connected on state stream
      when(
        () => mockWsClient.state,
      ).thenReturn(WebSocketConnectionState.waitingToRetry);
      wsStateController.add(WebSocketConnectionState.waitingToRetry);
      await Future<void>.delayed(Duration.zero);

      when(
        () => mockWsClient.state,
      ).thenReturn(WebSocketConnectionState.connected);
      wsStateController.add(WebSocketConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      final deliveredEnvs = sentEnvelopes
          .where((e) => e.type == 'chat.delivered')
          .toList();

      // Exactly ONE chat.delivered sent for c1 with seq: 5
      expect(deliveredEnvs.length, 1);
      expect(deliveredEnvs.first.payload['conversation_id'], 'c1');
      expect(deliveredEnvs.first.payload['seq'], 5);

      // Nothing sent for c2 (own message) or c3 (current pointer)
      expect(
        deliveredEnvs.any((e) => e.payload['conversation_id'] == 'c2'),
        isFalse,
      );
      expect(
        deliveredEnvs.any((e) => e.payload['conversation_id'] == 'c3'),
        isFalse,
      );
    },
  );

  test(
    'Ack-tracking reset (delivered ack): resets tracking to REST pointer on reconnect and resends ack, does not advance tracking when socket down',
    () async {
      final initialConv = Conversation(
        id: 'c1',
        type: 'dm',
        lastSeq: 2,
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 2,
            lastReadSeq: 2,
          ),
          MembershipPointer(
            userId: 'user-bob',
            lastDeliveredSeq: 2,
            lastReadSeq: 2,
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      setupContainer(initialConvs: [initialConv]);
      final notifier = container.read(conversationsNotifierProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      final sentEnvelopes = <WsEnvelope>[];
      when(() => mockWsClient.sendEnvelope(any())).thenAnswer((invocation) {
        sentEnvelopes.add(invocation.positionalArguments[0] as WsEnvelope);
        return true;
      });

      // 1. Send a delivered ack for seq 10
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm10',
            'conversation_id': 'c1',
            'sender_id': 'user-bob',
            'seq': 10,
            'body': 'Message 10',
            'client_id': 'b10',
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        sentEnvelopes
            .where((e) => e.type == 'chat.delivered' && e.payload['seq'] == 10)
            .length,
        1,
      );
      expect(notifier.lastDeliveredAckSent('c1'), 10);

      // 2. Drop the socket
      when(
        () => mockWsClient.state,
      ).thenReturn(WebSocketConnectionState.waitingToRetry);
      wsStateController.add(WebSocketConnectionState.waitingToRetry);
      await Future<void>.delayed(Duration.zero);

      // Try to send ack when socket is down (seq 12)
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.receive',
          payload: {
            'id': 'm12',
            'conversation_id': 'c1',
            'sender_id': 'user-bob',
            'seq': 12,
            'body': 'Message 12',
            'client_id': 'b12',
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));

      // Assert tracking value is NOT advanced when socket was down at send time
      expect(notifier.lastDeliveredAckSent('c1'), 10);

      // 3. Reconnect with a REST payload whose pointers are LOWER than what was tracked (simulating a lost ack)
      final lostAckConv = Conversation(
        id: 'c1',
        type: 'dm',
        lastSeq: 10,
        lastMessage: ChatMessage(
          id: 'm10',
          conversationId: 'c1',
          senderId: 'user-bob',
          seq: 10,
          body: 'Message 10',
          clientId: 'b10',
          createdAt: DateTime.now().toUtc(),
        ),
        memberships: [
          MembershipPointer(
            userId: 'user-me',
            lastDeliveredSeq: 4, // LOWER than tracked (10)
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

      when(
        () => mockRepo.getConversations(),
      ).thenAnswer((_) async => [lostAckConv]);
      sentEnvelopes.clear();

      when(
        () => mockWsClient.state,
      ).thenReturn(WebSocketConnectionState.connected);
      wsStateController.add(WebSocketConnectionState.connected);
      await Future<void>.delayed(Duration.zero);

      // The tracking value reset to REST pointer (4), and the ack is sent again for 10
      final resendDelivered = sentEnvelopes
          .where(
            (e) =>
                e.type == 'chat.delivered' &&
                e.payload['conversation_id'] == 'c1',
          )
          .toList();
      expect(resendDelivered.length, 1);
      expect(resendDelivered.first.payload['seq'], 10);
      expect(notifier.lastDeliveredAckSent('c1'), 10);
    },
  );

  test(
    'Older REST payload: status event sets delivered=10/read=8, REST payload returns 5/3 -> pointers stay 10/8 and ticks do not regress',
    () async {
      final initialConv = Conversation(
        id: 'c1',
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

      setupContainer(initialConvs: [initialConv]);
      final notifier = container.read(conversationsNotifierProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      // 1. Live status event delivered=10/read=8
      wsEventsController.add(
        WsEnvelope(
          type: 'chat.status',
          payload: {
            'conversation_id': 'c1',
            'user_id': 'user-bob',
            'delivered_seq': 10,
            'read_seq': 8,
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var conv = container
          .read(conversationsNotifierProvider)
          .asData!
          .value
          .first;
      expect(conv.otherDeliveredSeq, 10);
      expect(conv.otherReadSeq, 8);

      // 2. Hydrate from older REST payload with delivered=5/read=3
      final olderConv = Conversation(
        id: 'c1',
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
      await notifier.load();

      conv = container.read(conversationsNotifierProvider).asData!.value.first;

      // Assert pointers stay 10/8
      expect(conv.otherDeliveredSeq, 10);
      expect(conv.otherReadSeq, 8);

      // Assert ticks don't regress
      final myMsgSeq8 = ChatMessage(
        id: 'm8',
        conversationId: 'c1',
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
          otherDeliveredSeq: conv.otherDeliveredSeq,
          otherReadSeq: conv.otherReadSeq,
        ),
        MessageTickStatus.read,
      );

      final myMsgSeq10 = ChatMessage(
        id: 'm10',
        conversationId: 'c1',
        senderId: 'user-me',
        seq: 10,
        body: 'Message 10',
        clientId: 'me10',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      );
      expect(
        myMsgSeq10.getTickStatus(
          isMe: true,
          otherDeliveredSeq: conv.otherDeliveredSeq,
          otherReadSeq: conv.otherReadSeq,
        ),
        MessageTickStatus.delivered,
      );
    },
  );
}
