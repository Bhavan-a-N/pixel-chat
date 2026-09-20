import 'dart:async';
import 'package:dio/dio.dart';
import '../storage/token_storage.dart';

class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    required this.tokenStorage,
    required this.refreshDio,
    required this.mainDio,
    this.onSessionExpired,
  });

  final TokenStorage tokenStorage;
  final Dio refreshDio;
  final Dio mainDio;
  final void Function()? onSessionExpired;

  Completer<String?>? _refreshCompleter;

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

    // Single-flight refresh coordination
    if (_refreshCompleter != null) {
      try {
        final newAccessToken = await _refreshCompleter!.future;
        if (newAccessToken != null && newAccessToken.isNotEmpty) {
          err.requestOptions.headers['Authorization'] =
              'Bearer $newAccessToken';
          final response = await mainDio.fetch(err.requestOptions);
          return handler.resolve(response);
        } else {
          return handler.next(err);
        }
      } catch (_) {
        return handler.next(err);
      }
    }

    final completer = Completer<String?>();
    _refreshCompleter = completer;

    try {
      final refreshToken = await tokenStorage.getRefreshToken();
      if (refreshToken == null || refreshToken.isEmpty) {
        completer.complete(null);
        _refreshCompleter = null;
        await tokenStorage.clearTokens();
        onSessionExpired?.call();
        return handler.next(err);
      }

      final refreshResponse = await refreshDio.post<Map<String, dynamic>>(
        '/api/auth/refresh',
        data: {'refresh': refreshToken},
      );

      final data = refreshResponse.data;
      final newAccess = data?['access'] as String?;
      final newRefresh = data?['refresh'] as String?;

      if (newAccess != null && newRefresh != null) {
        await tokenStorage.saveTokens(access: newAccess, refresh: newRefresh);

        completer.complete(newAccess);
        _refreshCompleter = null;

        err.requestOptions.headers['Authorization'] = 'Bearer $newAccess';
        final retriedResponse = await mainDio.fetch(err.requestOptions);
        return handler.resolve(retriedResponse);
      } else {
        completer.complete(null);
        _refreshCompleter = null;
        return handler.next(err);
      }
    } on DioException catch (refreshErr) {
      completer.complete(null);
      _refreshCompleter = null;

      final refreshStatusCode = refreshErr.response?.statusCode;
      // Log out ONLY if the server rejects the refresh token (401/400).
      // Timeouts and connection errors must NOT log out.
      if (refreshStatusCode == 400 || refreshStatusCode == 401) {
        await tokenStorage.clearTokens();
        onSessionExpired?.call();
      }

      return handler.next(err);
    } catch (_) {
      completer.complete(null);
      _refreshCompleter = null;
      return handler.next(err);
    }
  }
}
