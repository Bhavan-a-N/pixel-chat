import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/env.dart';
import '../storage/token_storage.dart';
import 'auth_interceptor.dart';
import 'token_refresher.dart';
import '../../features/auth/data/auth_repository.dart';

final tokenStorageProvider = Provider<TokenStorage>((ref) {
  return SecureTokenStorage();
});

class SessionExpiredNotifier extends Notifier<void Function()?> {
  @override
  void Function()? build() => null;

  void setCallback(void Function()? callback) {
    state = callback;
  }
}

final onSessionExpiredProvider =
    NotifierProvider<SessionExpiredNotifier, void Function()?>(
      SessionExpiredNotifier.new,
    );

final refreshDioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppEnv.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ),
  );
  return dio;
});

final tokenRefresherProvider = Provider<TokenRefresher>((ref) {
  final tokenStorage = ref.watch(tokenStorageProvider);
  final refreshDio = ref.watch(refreshDioProvider);
  return TokenRefresher(
    tokenStorage: tokenStorage,
    refreshDio: refreshDio,
    onSessionExpired: () {
      final callback = ref.read(onSessionExpiredProvider);
      callback?.call();
    },
  );
});

final mainDioProvider = Provider<Dio>((ref) {
  final tokenStorage = ref.watch(tokenStorageProvider);
  final refreshDio = ref.watch(refreshDioProvider);
  final tokenRefresher = ref.watch(tokenRefresherProvider);

  final dio = Dio(
    BaseOptions(
      baseUrl: AppEnv.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ),
  );

  dio.interceptors.add(
    AuthInterceptor(
      tokenStorage: tokenStorage,
      refreshDio: refreshDio,
      mainDio: dio,
      tokenRefresher: tokenRefresher,
      onSessionExpired: () {
        final callback = ref.read(onSessionExpiredProvider);
        callback?.call();
      },
    ),
  );

  return dio;
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final dio = ref.watch(mainDioProvider);
  final tokenStorage = ref.watch(tokenStorageProvider);
  return AuthRepositoryImpl(dio: dio, tokenStorage: tokenStorage);
});
