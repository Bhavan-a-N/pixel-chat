import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_error.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/storage/token_storage.dart';
import '../data/auth_repository.dart';
import 'auth_state.dart';

class AuthNotifier extends Notifier<AuthState> {
  AuthRepository get _authRepository => ref.read(authRepositoryProvider);
  TokenStorage get _tokenStorage => ref.read(tokenStorageProvider);

  @override
  AuthState build() {
    // Hook interceptor session expiration to notifier
    ref.read(onSessionExpiredProvider.notifier).setCallback(() {
      onSessionExpired();
    });

    // Run bootstrap asynchronously after build returns initial state
    Future.microtask(_bootstrap);

    return const AuthState.unknown();
  }

  Future<void> _bootstrap() async {
    try {
      final access = await _tokenStorage.getAccessToken();
      final refresh = await _tokenStorage.getRefreshToken();

      if (access == null && refresh == null) {
        state = const AuthState.unauthenticated();
        return;
      }

      final user = await _authRepository.getMe();
      state = AuthState.authenticated(user);
    } on ApiError catch (e) {
      if (e.isNetworkError || e.code >= 500) {
        state = AuthState.networkError(e.friendlyMessage);
      } else if (e.code == 401 || e.code == 403) {
        await _tokenStorage.clearTokens();
        state = const AuthState.unauthenticated();
      } else {
        state = AuthState.networkError(e.friendlyMessage);
      }
    } catch (_) {
      state = const AuthState.networkError(
        'Failed to connect to server. Please try again.',
      );
    }
  }

  Future<void> retryBootstrap() async {
    state = const AuthState.unknown();
    await _bootstrap();
  }

  Future<void> login({required String email, required String password}) async {
    await _authRepository.login(email: email, password: password);
    final user = await _authRepository.getMe();
    state = AuthState.authenticated(user);
  }

  Future<void> register({
    required String email,
    required String username,
    required String password,
    required String displayName,
    required String inviteCode,
  }) async {
    await _authRepository.register(
      email: email,
      username: username,
      password: password,
      displayName: displayName,
      inviteCode: inviteCode,
    );
    // Auto-login after successful registration
    await login(email: email, password: password);
  }

  Future<void> logout() async {
    await _authRepository.logout();
    state = const AuthState.unauthenticated();
  }

  void onSessionExpired() {
    state = const AuthState.unauthenticated();
  }
}

final authNotifierProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);
