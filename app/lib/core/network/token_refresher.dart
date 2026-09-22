import 'dart:async';
import 'package:dio/dio.dart';
import '../storage/token_storage.dart';

/// Single-flight token refresher coordinating JWT refresh requests across
/// REST interceptors and the WebSocket client.
class TokenRefresher {
  TokenRefresher({
    required this.tokenStorage,
    required this.refreshDio,
    this.onSessionExpired,
  });

  final TokenStorage tokenStorage;
  final Dio refreshDio;
  final void Function()? onSessionExpired;

  Completer<String?>? _refreshCompleter;

  /// Attempts to refresh the access token using the stored refresh token.
  ///
  /// Concurrent calls coalesce onto the same in-flight future.
  /// Throws [DioException] on failure so callers can distinguish between
  /// rejection (400/401) and network/server errors.
  Future<String?> refreshToken() async {
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
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
        return null;
      }

      final response = await refreshDio.post<Map<String, dynamic>>(
        '/api/auth/refresh',
        data: {'refresh': refreshToken},
      );

      final data = response.data;
      final newAccess = data?['access'] as String?;
      final newRefresh = data?['refresh'] as String?;

      if (newAccess != null && newRefresh != null) {
        await tokenStorage.saveTokens(access: newAccess, refresh: newRefresh);
        completer.complete(newAccess);
        _refreshCompleter = null;
        return newAccess;
      } else {
        completer.complete(null);
        _refreshCompleter = null;
        return null;
      }
    } on DioException catch (e) {
      completer.complete(null);
      _refreshCompleter = null;

      final statusCode = e.response?.statusCode;
      // Log out ONLY if the server rejected the refresh token (400 or 401).
      // Timeouts and connection errors must NOT log out.
      if (statusCode == 400 || statusCode == 401) {
        await tokenStorage.clearTokens();
        onSessionExpired?.call();
      }
      rethrow;
    } catch (e) {
      completer.complete(null);
      _refreshCompleter = null;
      rethrow;
    }
  }
}
