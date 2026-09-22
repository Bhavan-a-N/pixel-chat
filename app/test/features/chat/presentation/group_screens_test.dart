import 'package:flutter/material.dart';
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
import 'package:pixel_chat/features/chat/presentation/create_group_screen.dart';
import 'package:pixel_chat/features/chat/presentation/group_details_screen.dart';

class MockChatRepository extends Mock implements ChatRepository {}

class MockChatWebSocketClient extends Mock implements ChatWebSocketClient {}

class FakeAuthNotifier extends AuthNotifier {
  FakeAuthNotifier(this._initialState);
  final AuthState _initialState;

  @override
  AuthState build() => _initialState;
}

void main() {
  final currentUser = User(
    id: 'user-admin',
    username: 'admin',
    displayName: 'Admin User',
    avatarSeed: 'admin-seed',
    createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
  );

  final bobUser = User(
    id: 'user-bob',
    username: 'bob',
    displayName: 'Bob Smith',
    avatarSeed: 'bob-seed',
    createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
  );

  late MockChatRepository mockRepo;
  late MockChatWebSocketClient mockWsClient;

  setUp(() {
    mockRepo = MockChatRepository();
    mockWsClient = MockChatWebSocketClient();

    when(
      () => mockWsClient.incomingEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => mockWsClient.stateStream,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => mockWsClient.state,
    ).thenReturn(WebSocketConnectionState.connected);
  });

  Widget createWidgetUnderTest(Widget child) {
    return ProviderScope(
      overrides: [
        authNotifierProvider.overrideWith(
          () => FakeAuthNotifier(AuthState.authenticated(currentUser)),
        ),
        chatRepositoryProvider.overrideWithValue(mockRepo),
        chatWebSocketClientProvider.overrideWithValue(mockWsClient),
      ],
      child: MaterialApp(home: child),
    );
  }

  testWidgets('CreateGroupScreen: validates group name and selected members', (
    tester,
  ) async {
    when(() => mockRepo.searchUsers('bob')).thenAnswer((_) async => [bobUser]);

    await tester.pumpWidget(createWidgetUnderTest(const CreateGroupScreen()));

    // Create button is disabled when name is empty
    final createBtn = find.byKey(const Key('create_group_submit_button'));
    expect(createBtn, findsOneWidget);
    final textButton = tester.widget<TextButton>(createBtn);
    expect(textButton.onPressed, isNull);

    // Enter name
    await tester.enterText(
      find.byKey(const Key('group_name_input')),
      'Mobile Team',
    );
    await tester.pump();

    // Now create button is enabled
    final enabledBtn = tester.widget<TextButton>(createBtn);
    expect(enabledBtn.onPressed, isNotNull);

    // Search user
    await tester.enterText(find.byKey(const Key('member_search_input')), 'bob');
    // wait for debounce timer
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.text('Bob Smith'), findsOneWidget);
    await tester.tap(find.text('Bob Smith'));
    await tester.pump();

    // Verify user chip is selected
    expect(
      find.byKey(const Key('selected_user_chip_user-bob')),
      findsOneWidget,
    );
  });

  testWidgets('GroupDetailsScreen: renders members and roles', (tester) async {
    const groupDetail = GroupDetail(
      id: 'grp-1',
      name: 'Engineering Team',
      memberCount: 2,
      members: [
        GroupMember(
          id: 'user-admin',
          username: 'admin',
          displayName: 'Admin User',
          avatarSeed: 'admin-seed',
          role: 'admin',
          isOnline: true,
        ),
        GroupMember(
          id: 'user-bob',
          username: 'bob',
          displayName: 'Bob Smith',
          avatarSeed: 'bob-seed',
          role: 'member',
          isOnline: false,
        ),
      ],
    );

    when(
      () => mockRepo.getGroupDetail('grp-1'),
    ).thenAnswer((_) async => groupDetail);
    when(
      () => mockRepo.getPresence(['user-admin', 'user-bob']),
    ).thenAnswer((_) async => {'user-admin': true, 'user-bob': false});

    await tester.pumpWidget(
      createWidgetUnderTest(const GroupDetailsScreen(conversationId: 'grp-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Engineering Team'), findsOneWidget);
    expect(find.text('2 members'), findsOneWidget);
    expect(find.text('Admin User'), findsOneWidget);
    expect(find.text('(You)'), findsOneWidget);
    expect(find.text('Bob Smith'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);

    // Admin should see action button on Bob
    expect(
      find.byKey(const Key('member_actions_button_user-bob')),
      findsOneWidget,
    );

    // Admin should NOT see action button on self
    expect(
      find.byKey(const Key('member_actions_button_user-admin')),
      findsNothing,
    );
  });
}
