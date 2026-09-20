import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pixel_chat/core/network/api_error.dart';
import 'package:pixel_chat/core/network/dio_provider.dart';
import 'package:pixel_chat/core/storage/token_storage.dart';
import 'package:pixel_chat/core/theme/app_theme.dart';
import 'package:pixel_chat/features/auth/data/auth_repository.dart';
import 'package:pixel_chat/features/auth/domain/auth_tokens.dart';
import 'package:pixel_chat/features/auth/domain/user.dart';
import 'package:pixel_chat/features/auth/presentation/signup_screen.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

class MockTokenStorage extends Mock implements TokenStorage {}

void main() {
  late MockAuthRepository mockAuthRepository;
  late MockTokenStorage mockTokenStorage;

  setUp(() {
    mockAuthRepository = MockAuthRepository();
    mockTokenStorage = MockTokenStorage();

    when(() => mockTokenStorage.getAccessToken()).thenAnswer((_) async => null);
    when(
      () => mockTokenStorage.getRefreshToken(),
    ).thenAnswer((_) async => null);
    when(() => mockTokenStorage.clearTokens()).thenAnswer((_) async {});
    when(
      () => mockTokenStorage.saveTokens(
        access: any(named: 'access'),
        refresh: any(named: 'refresh'),
      ),
    ).thenAnswer((_) async {});
  });

  Widget createWidgetUnderTest() {
    return ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(mockAuthRepository),
        tokenStorageProvider.overrideWithValue(mockTokenStorage),
      ],
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        home: const SignupScreen(),
      ),
    );
  }

  group('SignupScreen', () {
    testWidgets('renders all fields and buttons', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Create Account'), findsOneWidget);
      expect(find.byKey(const Key('signup_email_field')), findsOneWidget);
      expect(find.byKey(const Key('signup_username_field')), findsOneWidget);
      expect(
        find.byKey(const Key('signup_display_name_field')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('signup_password_field')), findsOneWidget);
      expect(find.byKey(const Key('signup_invite_code_field')), findsOneWidget);
      expect(find.byKey(const Key('signup_submit_button')), findsOneWidget);
      expect(find.byKey(const Key('signup_to_login_button')), findsOneWidget);
    });

    testWidgets('validates required fields on submit', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('signup_submit_button')));
      await tester.tap(find.byKey(const Key('signup_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Email is required'), findsOneWidget);
      expect(find.text('Username is required'), findsOneWidget);
      expect(find.text('Display name is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);
      expect(find.text('Invite code is required'), findsOneWidget);
    });

    testWidgets('validates username rules (length and charset)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      // Too short
      await tester.enterText(
        find.byKey(const Key('signup_username_field')),
        'ab',
      );
      await tester.ensureVisible(find.byKey(const Key('signup_submit_button')));
      await tester.tap(find.byKey(const Key('signup_submit_button')));
      await tester.pumpAndSettle();
      expect(
        find.text('Username must be at least 3 characters'),
        findsOneWidget,
      );

      // Invalid characters
      await tester.enterText(
        find.byKey(const Key('signup_username_field')),
        'bob@invalid',
      );
      await tester.ensureVisible(find.byKey(const Key('signup_submit_button')));
      await tester.tap(find.byKey(const Key('signup_submit_button')));
      await tester.pumpAndSettle();
      expect(
        find.text('Only letters, numbers, and underscores allowed'),
        findsOneWidget,
      );
    });

    testWidgets('validates password length (min 8 characters)', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('signup_password_field')),
        'short',
      );
      await tester.ensureVisible(find.byKey(const Key('signup_submit_button')));
      await tester.tap(find.byKey(const Key('signup_submit_button')));
      await tester.pumpAndSettle();
      expect(
        find.text('Password must be at least 8 characters'),
        findsOneWidget,
      );
    });

    testWidgets('calls register and handles backend duplicate error shape', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      when(
        () => mockAuthRepository.register(
          email: any(named: 'email'),
          username: any(named: 'username'),
          password: any(named: 'password'),
          displayName: any(named: 'displayName'),
          inviteCode: any(named: 'inviteCode'),
        ),
      ).thenThrow(
        const ApiError(
          code: 400,
          message: 'Bad Request',
          details: {
            'username': ['user with this username already exists.'],
          },
        ),
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('signup_email_field')),
        'test@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('signup_username_field')),
        'bob',
      );
      await tester.enterText(
        find.byKey(const Key('signup_display_name_field')),
        'Bob Test',
      );
      await tester.enterText(
        find.byKey(const Key('signup_password_field')),
        'Password123!',
      );
      await tester.enterText(
        find.byKey(const Key('signup_invite_code_field')),
        'pixelchat2026',
      );

      await tester.ensureVisible(find.byKey(const Key('signup_submit_button')));
      await tester.tap(find.byKey(const Key('signup_submit_button')));
      await tester.pumpAndSettle();

      verify(
        () => mockAuthRepository.register(
          email: 'test@example.com',
          username: 'bob',
          password: 'Password123!',
          displayName: 'Bob Test',
          inviteCode: 'pixelchat2026',
        ),
      ).called(1);

      expect(
        find.text('user with this username already exists.'),
        findsOneWidget,
      );
    });

    testWidgets('calls register and logs in on success', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      when(
        () => mockAuthRepository.register(
          email: any(named: 'email'),
          username: any(named: 'username'),
          password: any(named: 'password'),
          displayName: any(named: 'displayName'),
          inviteCode: any(named: 'inviteCode'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockAuthRepository.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenAnswer(
        (_) async => const AuthTokens(access: 'acc', refresh: 'ref'),
      );

      when(() => mockAuthRepository.getMe()).thenAnswer(
        (_) async => User(
          id: '123',
          username: 'bob',
          displayName: 'Bob Test',
          avatarSeed: 'seed',
          createdAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('signup_email_field')),
        'test@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('signup_username_field')),
        'bob',
      );
      await tester.enterText(
        find.byKey(const Key('signup_display_name_field')),
        'Bob Test',
      );
      await tester.enterText(
        find.byKey(const Key('signup_password_field')),
        'Password123!',
      );
      await tester.enterText(
        find.byKey(const Key('signup_invite_code_field')),
        'pixelchat2026',
      );

      await tester.ensureVisible(find.byKey(const Key('signup_submit_button')));
      await tester.tap(find.byKey(const Key('signup_submit_button')));
      await tester.pumpAndSettle();

      verify(
        () => mockAuthRepository.register(
          email: 'test@example.com',
          username: 'bob',
          password: 'Password123!',
          displayName: 'Bob Test',
          inviteCode: 'pixelchat2026',
        ),
      ).called(1);

      verify(
        () => mockAuthRepository.login(
          email: 'test@example.com',
          password: 'Password123!',
        ),
      ).called(1);

      verify(() => mockAuthRepository.getMe()).called(1);
    });
  });
}
