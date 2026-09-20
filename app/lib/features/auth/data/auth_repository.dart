import 'package:dio/dio.dart';
import '../../../core/network/api_error.dart';
import '../../../core/storage/token_storage.dart';
import '../domain/auth_tokens.dart';
import '../domain/user.dart';

abstract class AuthRepository {
  Future<AuthTokens> login({required String email, required String password});

  Future<void> register({
    required String email,
    required String username,
    required String password,
    required String displayName,
    required String inviteCode,
  });

  Future<User> getMe();

  Future<void> logout();
}

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl({required Dio dio, required TokenStorage tokenStorage})
    : _dio = dio,
      _tokenStorage = tokenStorage;

  final Dio _dio;
  final TokenStorage _tokenStorage;

  @override
  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/auth/login',
        data: {'email': email.trim().toLowerCase(), 'password': password},
      );

      final tokens = AuthTokens.fromJson(response.data ?? {});
      await _tokenStorage.saveTokens(
        access: tokens.access,
        refresh: tokens.refresh,
      );
      return tokens;
    } on DioException catch (e) {
      throw ApiError.fromDioException(e);
    }
  }

  @override
  Future<void> register({
    required String email,
    required String username,
    required String password,
    required String displayName,
    required String inviteCode,
  }) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '/api/auth/register',
        data: {
          'email': email.trim().toLowerCase(),
          'username': username.trim(),
          'password': password,
          'display_name': displayName.trim(),
          'invite_code': inviteCode.trim(),
        },
      );
    } on DioException catch (e) {
      throw ApiError.fromDioException(e);
    }
  }

  @override
  Future<User> getMe() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/api/auth/me');
      return User.fromJson(response.data ?? {});
    } on DioException catch (e) {
      throw ApiError.fromDioException(e);
    }
  }

  @override
  Future<void> logout() async {
    try {
      final refresh = await _tokenStorage.getRefreshToken();
      if (refresh != null && refresh.isNotEmpty) {
        await _dio.post('/api/auth/logout', data: {'refresh': refresh});
      }
    } catch (_) {
      // Logout is best-effort on server side
    } finally {
      await _tokenStorage.clearTokens();
    }
  }
}
