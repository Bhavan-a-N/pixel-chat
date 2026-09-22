import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pixel_chat/core/network/websocket_client.dart';
import 'package:pixel_chat/core/theme/app_theme.dart';
import 'package:pixel_chat/features/auth/application/auth_notifier.dart';
import 'package:pixel_chat/features/auth/application/auth_state.dart';
import 'package:pixel_chat/features/auth/domain/user.dart';
import 'package:pixel_chat/features/chat/application/conversations_notifier.dart';
import 'package:pixel_chat/features/chat/application/websocket_provider.dart';
import 'package:pixel_chat/features/chat/data/chat_repository.dart';
import 'package:pixel_chat/features/chat/domain/chat_models.dart';
import 'package:pixel_chat/features/chat/presentation/chat_screen.dart';

class MockChatRepository extends Mock implements ChatRepository {}

class MockChatWebSocketClient extends Mock implements ChatWebSocketClient {}

class FakeWsEnvelope extends Fake implements WsEnvelope {}

class FakeAuthNotifier extends AuthNotifier {
  FakeAuthNotifier(this._initialState);
  final AuthState _initialState;

  @override
  AuthState build() => _initialState;
}

class FakeWebSocketStateNotifier extends WebSocketStateNotifier {
  FakeWebSocketStateNotifier(this._initial);
  final WebSocketConnectionState _initial;

  @override
  WebSocketConnectionState build() => _initial;
}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeWsEnvelope());
  });

  late MockChatRepository mockRepo;
  late MockChatWebSocketClient mockWsClient;
  late StreamController<WebSocketConnectionState> wsStateController;
  late StreamController<WsEnvelope> wsEventsController;

  const testConvId = 'conv-456';
  final testUser = User(
    id: 'user-me',
    username: 'me',
    displayName: 'Myself',
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
    wsStateController.close();
    wsEventsController.close();
  });

  Widget createWidgetUnderTest({List<ChatMessage>? initialMessages}) {
    when(() => mockRepo.getConversations()).thenAnswer((_) async => []);
    when(
      () => mockRepo.getMessages(testConvId, limit: any(named: 'limit')),
    ).thenAnswer((_) async => initialMessages ?? []);

    return ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepo),
        chatWebSocketClientProvider.overrideWithValue(mockWsClient),
        webSocketStateProvider.overrideWith(
          () => FakeWebSocketStateNotifier(WebSocketConnectionState.connected),
        ),
        authNotifierProvider.overrideWith(
          () => FakeAuthNotifier(AuthState.authenticated(testUser)),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const ChatScreen(conversationId: testConvId),
      ),
    );
  }

  testWidgets('renders message bubbles for own and other messages', (
    tester,
  ) async {
    final messages = [
      ChatMessage(
        id: 'm1',
        conversationId: testConvId,
        senderId: 'user-bob',
        seq: 1,
        body: 'Hello from Bob',
        clientId: 'c1',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      ),
      ChatMessage(
        id: 'm2',
        conversationId: testConvId,
        senderId: 'user-me',
        seq: 2,
        body: 'Hello Bob!',
        clientId: 'c2',
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.sent,
      ),
    ];

    await tester.pumpWidget(createWidgetUnderTest(initialMessages: messages));
    await tester.pumpAndSettle();

    expect(find.text('Hello from Bob'), findsOneWidget);
    expect(find.text('Hello Bob!'), findsOneWidget);
  });

  testWidgets('optimistic send shows message immediately in pending state', (
    tester,
  ) async {
    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('chat_message_input')),
      'Sending this right now',
    );
    await tester.tap(find.byKey(const Key('chat_send_button')));
    await tester.pump();

    expect(find.text('Sending this right now'), findsOneWidget);
    expect(find.byIcon(Icons.access_time_rounded), findsOneWidget);
  });

  testWidgets(
    'shows retry button when message fails and retrying resends message',
    (tester) async {
      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('chat_message_input')),
        'Will fail',
      );
      await tester.tap(find.byKey(const Key('chat_send_button')));
      await tester.pump();

      // Find the client id from the bubble key
      final bubbleFinder = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('message_bubble_'),
      );
      expect(bubbleFinder, findsOneWidget);
      final key = bubbleFinder.evaluate().first.widget.key as ValueKey<String>;
      final clientId = key.value.replaceFirst('message_bubble_', '');

      // Server returns error 400
      wsEventsController.add(
        WsEnvelope(
          type: 'error',
          clientId: clientId,
          payload: {
            'client_id': clientId,
            'code': 400,
            'message': 'Failed validation',
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Failed validation'), findsOneWidget);
      expect(find.byKey(Key('retry_button_$clientId')), findsOneWidget);

      // Tap retry button
      await tester.tap(find.byKey(Key('retry_button_$clientId')));
      await tester.pump();

      expect(find.byIcon(Icons.access_time_rounded), findsOneWidget);
    },
  );
}
