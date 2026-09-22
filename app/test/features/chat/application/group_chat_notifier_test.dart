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

  final testUser = User(
    id: 'user-me',
    username: 'me',
    displayName: 'My Name',
    avatarSeed: 'seed',
    createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
  );

  const convId = 'grp-123';

  late MockChatRepository mockRepo;
  late MockChatWebSocketClient mockWsClient;
  late StreamController<WsEnvelope> incomingController;
  late StreamController<WebSocketConnectionState> wsStateController;
  late ProviderContainer container;

  setUp(() {
    mockRepo = MockChatRepository();
    mockWsClient = MockChatWebSocketClient();
    incomingController = StreamController<WsEnvelope>.broadcast();
    wsStateController = StreamController<WebSocketConnectionState>.broadcast();

    when(
      () => mockWsClient.incomingEvents,
    ).thenAnswer((_) => incomingController.stream);
    when(
      () => mockWsClient.stateStream,
    ).thenAnswer((_) => wsStateController.stream);
    when(
      () => mockWsClient.state,
    ).thenReturn(WebSocketConnectionState.connected);
    when(() => mockWsClient.sendEnvelope(any())).thenReturn(true);

    when(
      () => mockRepo.getMessages(convId, limit: any(named: 'limit')),
    ).thenAnswer((_) async => []);

    container = ProviderContainer(
      overrides: [
        authNotifierProvider.overrideWith(
          () => FakeAuthNotifier(AuthState.authenticated(testUser)),
        ),
        chatRepositoryProvider.overrideWithValue(mockRepo),
        chatWebSocketClientProvider.overrideWithValue(mockWsClient),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    incomingController.close();
    wsStateController.close();
  });

  test('Typing indicator: single user and multiple users formatting', () async {
    final notifier = container.read(
      chatMessagesNotifierProvider(convId).notifier,
    );
    await notifier.loadInitial();

    // 1 user typing
    incomingController.add(
      WsEnvelope(
        type: 'chat.typing',
        payload: {
          'conversation_id': convId,
          'user_id': 'user-alice',
          'username': 'alice',
          'display_name': 'Alice Smith',
          'is_typing': true,
        },
      ),
    );
    await pumpEventQueue();

    var state = container.read(chatMessagesNotifierProvider(convId));
    expect(state.typingUsers.length, 1);
    expect(state.typingText, 'Alice Smith is typing...');

    // Second user typing
    incomingController.add(
      WsEnvelope(
        type: 'chat.typing',
        payload: {
          'conversation_id': convId,
          'user_id': 'user-bob',
          'username': 'bob',
          'display_name': 'Bob Jones',
          'is_typing': true,
        },
      ),
    );
    await pumpEventQueue();

    state = container.read(chatMessagesNotifierProvider(convId));
    expect(state.typingUsers.length, 2);
    expect(state.typingText, '2 people are typing...');

    // Alice stops typing
    incomingController.add(
      WsEnvelope(
        type: 'chat.typing',
        payload: {
          'conversation_id': convId,
          'user_id': 'user-alice',
          'is_typing': false,
        },
      ),
    );
    await pumpEventQueue();

    state = container.read(chatMessagesNotifierProvider(convId));
    expect(state.typingUsers.length, 1);
    expect(state.typingText, 'Bob Jones is typing...');
  });

  test(
    'membership.removed marks user as removed and discards outbox (Amendment 6)',
    () async {
      final notifier = container.read(
        chatMessagesNotifierProvider(convId).notifier,
      );
      await notifier.loadInitial();

      // Queue a message
      when(() => mockWsClient.sendEnvelope(any())).thenReturn(false);
      notifier.sendMessage('Unsent message');
      var state = container.read(chatMessagesNotifierProvider(convId));
      expect(state.messages.length, 1);

      // Event saying current user was removed
      incomingController.add(
        WsEnvelope(
          type: 'membership.removed',
          payload: {'conversation_id': convId, 'user_id': 'user-me'},
        ),
      );
      await pumpEventQueue();

      state = container.read(chatMessagesNotifierProvider(convId));
      expect(state.isRemovedFromGroup, true);

      // Reconnecting does not resend the discarded outbox
      clearInteractions(mockWsClient);
      wsStateController.add(WebSocketConnectionState.connected);
      await pumpEventQueue();
      verifyNever(() => mockWsClient.sendEnvelope(any()));
    },
  );

  test(
    '403 or "not a member" error marks user as removed and discards outbox (Amendment 6)',
    () async {
      final notifier = container.read(
        chatMessagesNotifierProvider(convId).notifier,
      );
      await notifier.loadInitial();

      notifier.sendMessage('Hello group');
      final clientMsg = container
          .read(chatMessagesNotifierProvider(convId))
          .messages
          .first;

      // Receive 403 not a member error
      incomingController.add(
        WsEnvelope(
          type: 'error',
          clientId: clientMsg.clientId,
          payload: {
            'client_id': clientMsg.clientId,
            'code': 403,
            'message': 'You are not a member of this conversation',
          },
        ),
      );
      await pumpEventQueue();

      final state = container.read(chatMessagesNotifierProvider(convId));
      expect(state.isRemovedFromGroup, true);
      // Message marked failed
      expect(state.messages.first.status, MessageStatus.failed);
    },
  );

  test(
    'sendTyping sends chat.typing over WebSocket when connected and not removed',
    () async {
      final notifier = container.read(
        chatMessagesNotifierProvider(convId).notifier,
      );
      await notifier.loadInitial();

      notifier.sendTyping(true);
      verify(
        () => mockWsClient.sendEnvelope(
          any(
            that: isA<WsEnvelope>()
                .having((e) => e.type, 'type', 'chat.typing')
                .having((e) => e.payload['conversation_id'], 'convId', convId)
                .having((e) => e.payload['is_typing'], 'isTyping', true),
          ),
        ),
      ).called(1);
    },
  );
}
