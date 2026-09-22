import 'dart:async';
import 'package:dio/dio.dart';
import '../storage/token_storage.dart';
import 'token_refresher.dart';

class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    required this.tokenStorage,
    required this.refreshDio,
    required this.mainDio,
    this.onSessionExpired,
    TokenRefresher? tokenRefresher,
  }) : tokenRefresher =
           tokenRefresher ??
           TokenRefresher(
             tokenStorage: tokenStorage,
             refreshDio: refreshDio,
             onSessionExpired: onSessionExpired,
           );

  final TokenStorage tokenStorage;
  final Dio refreshDio;
  final Dio mainDio;
  final void Function()? onSessionExpired;
  final TokenRefresher tokenRefresher;

  static const List<String> _skipRefreshEndpoints = [
    '/api/auth/login',
    '/api/auth/register',
    '/api/auth/refresh',
  ];

  bool _shouldSkipRefresh(String path) {
    return _skipRefreshEndpoints.any((endpoint) => path.contains(endpoint));
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final authHeader = options.headers['Authorization'];
    if (authHeader == null || (authHeader is String && authHeader.isEmpty)) {
      final token = await tokenStorage.getAccessToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final statusCode = err.response?.statusCode;
    final path = err.requestOptions.path;

    if (statusCode != 401 || _shouldSkipRefresh(path)) {
      return handler.next(err);
    }

    final rawHeader =
        err.requestOptions.headers['Authorization']?.toString() ?? '';
    final requestToken = rawHeader.startsWith('Bearer ')
        ? rawHeader.substring(7)
        : rawHeader;

    final currentStoredToken = await tokenStorage.getAccessToken();

    // If another request already refreshed the token, just retry with the current stored one.
    if (currentStoredToken != null &&
        currentStoredToken.isNotEmpty &&
        currentStoredToken != requestToken) {
      try {
        err.requestOptions.headers['Authorization'] =
            'Bearer $currentStoredToken';
        final response = await mainDio.fetch(err.requestOptions);
        return handler.resolve(response);
      } on DioException catch (e) {
        return handler.next(e);
      } catch (e) {
        return handler.next(err);
      }
    }

    try {
      final newAccess = await tokenRefresher.refreshToken();
      if (newAccess != null && newAccess.isNotEmpty) {
        err.requestOptions.headers['Authorization'] = 'Bearer $newAccess';
        final retriedResponse = await mainDio.fetch(err.requestOptions);
        return handler.resolve(retriedResponse);
      } else {
        return handler.next(err);
      }
    } on DioException {
      return handler.next(err);
    } catch (_) {
      return handler.next(err);
    }
  }
}
