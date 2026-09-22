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
import 'package:pixel_chat/features/chat/presentation/chat_list_screen.dart';

class MockChatRepository extends Mock implements ChatRepository {}

class MockChatWebSocketClient extends Mock implements ChatWebSocketClient {}

class FakeWsEnvelope extends Fake implements WsEnvelope {}

class FakeAuthNotifier extends AuthNotifier {
  FakeAuthNotifier(this._initialState);
  final AuthState _initialState;

  bool logoutCalled = false;

  @override
  AuthState build() => _initialState;

  @override
  Future<void> logout() async {
    logoutCalled = true;
    state = const AuthState.unauthenticated();
  }
}

class FakeWebSocketStateNotifier extends WebSocketStateNotifier {
  FakeWebSocketStateNotifier(this._initial);
  final WebSocketConnectionState _initial;

  @override
  WebSocketConnectionState build() => _initial;
}

void main() {
  late MockChatRepository mockRepo;
  late MockChatWebSocketClient mockWsClient;
  late StreamController<WebSocketConnectionState> wsStateController;
  late StreamController<WsEnvelope> wsEventsController;
  late FakeAuthNotifier fakeAuthNotifier;

  final testUser = User(
    id: 'user-me',
    username: 'alice',
    displayName: 'Alice In Wonderland',
    avatarSeed: 'seed',
    createdAt: DateTime.now().toUtc(),
  );

  final testConversation = Conversation(
    id: 'conv-1',
    type: 'dm',
    createdAt: DateTime.now().toUtc(),
    updatedAt: DateTime.now().toUtc(),
    lastSeq: 1,
    otherParticipant: User(
      id: 'user-bob',
      username: 'bob',
      displayName: 'Bob The Builder',
      avatarSeed: 'seed-bob',
      createdAt: DateTime.now().toUtc(),
    ),
    lastMessage: ChatMessage(
      id: 'm1',
      conversationId: 'conv-1',
      senderId: 'user-bob',
      seq: 1,
      body: 'Can we fix it?',
      clientId: 'c1',
      createdAt: DateTime.now().toUtc(),
      status: MessageStatus.sent,
    ),
  );

  setUpAll(() {
    registerFallbackValue(FakeWsEnvelope());
  });

  setUp(() {
    mockRepo = MockChatRepository();
    mockWsClient = MockChatWebSocketClient();
    wsStateController = StreamController<WebSocketConnectionState>.broadcast();
    wsEventsController = StreamController<WsEnvelope>.broadcast();

    fakeAuthNotifier = FakeAuthNotifier(AuthState.authenticated(testUser));

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

  Widget createWidgetUnderTest({
    List<Conversation>? conversations,
    WebSocketConnectionState wsState = WebSocketConnectionState.connected,
  }) {
    when(
      () => mockRepo.getConversations(),
    ).thenAnswer((_) async => conversations ?? [testConversation]);
    when(() => mockWsClient.state).thenReturn(wsState);

    return ProviderScope(
      overrides: [
        chatRepositoryProvider.overrideWithValue(mockRepo),
        chatWebSocketClientProvider.overrideWithValue(mockWsClient),
        webSocketStateProvider.overrideWith(
          () => FakeWebSocketStateNotifier(wsState),
        ),
        authNotifierProvider.overrideWith(() => fakeAuthNotifier),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const ChatListScreen(),
      ),
    );
  }

  testWidgets('renders user display name in app bar and logout button works', (
    tester,
  ) async {
    await tester.pumpWidget(createWidgetUnderTest());
    await tester.pumpAndSettle();

    expect(find.text('Pixel Chat'), findsOneWidget);
    expect(find.text('Alice In Wonderland'), findsOneWidget);
    expect(find.byKey(const Key('chat_list_logout_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat_list_logout_button')));
    await tester.pumpAndSettle();

    expect(fakeAuthNotifier.logoutCalled, true);
  });

  testWidgets(
    'renders conversation list with latest message and contact name',
    (tester) async {
      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Bob The Builder'), findsOneWidget);
      expect(find.text('Can we fix it?'), findsOneWidget);
    },
  );

  testWidgets('shows connection banner when server waking', (tester) async {
    await tester.pumpWidget(
      createWidgetUnderTest(wsState: WebSocketConnectionState.serverWaking),
    );
    await tester.pump();

    expect(find.text('Waking up server, please wait...'), findsOneWidget);
  });

  testWidgets(
    'shows user search dialog and searches for users with >= 2 characters',
    (tester) async {
      when(() => mockRepo.searchUsers('bo')).thenAnswer(
        (_) async => [
          User(
            id: 'user-bob',
            username: 'bob',
            displayName: 'Bob The Builder',
            avatarSeed: 'seed',
            createdAt: DateTime.now().toUtc(),
          ),
        ],
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('start_chat_fab')));
      await tester.pumpAndSettle();

      expect(find.text('Start a conversation'), findsOneWidget);
      expect(find.byKey(const Key('user_search_textfield')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('user_search_textfield')),
        'bo',
      );
      await tester.pumpAndSettle();

      verify(() => mockRepo.searchUsers('bo')).called(1);
      expect(find.text('Bob The Builder'), findsWidgets);
    },
  );
}
