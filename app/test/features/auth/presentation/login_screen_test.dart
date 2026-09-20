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
import 'package:pixel_chat/features/auth/presentation/login_screen.dart';

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
      child: MaterialApp(theme: AppTheme.lightTheme, home: const LoginScreen()),
    );
  }

  group('LoginScreen', () {
    testWidgets('renders all initial fields and buttons', (tester) async {
      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Welcome Back'), findsOneWidget);
      expect(find.byKey(const Key('login_email_field')), findsOneWidget);
      expect(find.byKey(const Key('login_password_field')), findsOneWidget);
      expect(find.byKey(const Key('login_submit_button')), findsOneWidget);
      expect(find.byKey(const Key('login_to_signup_button')), findsOneWidget);
    });

    testWidgets('shows validation errors for empty fields', (tester) async {
      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Email is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);
    });

    testWidgets('shows validation error for invalid email format', (
      tester,
    ) async {
      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('login_email_field')),
        'invalid-email',
      );
      await tester.enterText(
        find.byKey(const Key('login_password_field')),
        'Password123!',
      );

      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();

      expect(find.text('Please enter a valid email address'), findsOneWidget);
      verifyNever(
        () => mockAuthRepository.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      );
    });

    testWidgets('calls login and displays friendly message on 401 failure', (
      tester,
    ) async {
      when(
        () => mockAuthRepository.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
        ),
      ).thenThrow(const ApiError(code: 401, message: 'Authentication Failed'));

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('login_email_field')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('login_password_field')),
        'WrongPassword!',
      );

      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();

      verify(
        () => mockAuthRepository.login(
          email: 'user@example.com',
          password: 'WrongPassword!',
        ),
      ).called(1);

      // Must show friendly error message and never reveal if email exists
      expect(
        find.text('Invalid credentials. Please try again.'),
        findsOneWidget,
      );
    });

    testWidgets('successful login fetches user profile', (tester) async {
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
          username: 'testuser',
          displayName: 'Test User',
          avatarSeed: 'seed123',
          createdAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(createWidgetUnderTest());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('login_email_field')),
        'user@example.com',
      );
      await tester.enterText(
        find.byKey(const Key('login_password_field')),
        'Password123!',
      );

      await tester.tap(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();

      verify(
        () => mockAuthRepository.login(
          email: 'user@example.com',
          password: 'Password123!',
        ),
      ).called(1);
      verify(() => mockAuthRepository.getMe()).called(1);
    });
  });
}
