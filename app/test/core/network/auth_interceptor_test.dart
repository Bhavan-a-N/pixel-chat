import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_chat/core/network/auth_interceptor.dart';
import 'package:pixel_chat/core/storage/token_storage.dart';

class FakeTokenStorage implements TokenStorage {
  String? access;
  String? refresh;

  FakeTokenStorage({this.access, this.refresh});

  @override
  Future<void> clearTokens() async {
    access = null;
    refresh = null;
  }

  @override
  Future<String?> getAccessToken() async => access;

  @override
  Future<String?> getRefreshToken() async => refresh;

  @override
  Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    this.access = access;
    this.refresh = refresh;
  }
}

class TestAdapter implements HttpClientAdapter {
  TestAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

void main() {
  group('AuthInterceptor', () {
    late FakeTokenStorage tokenStorage;
    late Dio refreshDio;
    late Dio mainDio;
    late bool sessionExpiredCalled;

    setUp(() {
      tokenStorage = FakeTokenStorage(
        access: 'initial_access',
        refresh: 'initial_refresh',
      );
      sessionExpiredCalled = false;

      refreshDio = Dio(BaseOptions(baseUrl: 'http://test'));
      mainDio = Dio(BaseOptions(baseUrl: 'http://test'));

      mainDio.interceptors.add(
        AuthInterceptor(
          tokenStorage: tokenStorage,
          refreshDio: refreshDio,
          mainDio: mainDio,
          onSessionExpired: () {
            sessionExpiredCalled = true;
          },
        ),
      );
    });

    test('attaches access token to requests automatically', () async {
      RequestOptions? capturedOptions;

      mainDio.httpClientAdapter = TestAdapter((options) async {
        capturedOptions = options;
        return jsonResponse({'status': 'ok'});
      });

      await mainDio.get('/api/test');

      expect(
        capturedOptions?.headers['Authorization'],
        'Bearer initial_access',
      );
    });

    test('retries after successful token refresh on 401', () async {
      int mainAttempts = 0;
      int refreshAttempts = 0;

      refreshDio.httpClientAdapter = TestAdapter((options) async {
        refreshAttempts++;
        expect(options.path, '/api/auth/refresh');
        final data = options.data as Map;
        expect(data['refresh'], 'initial_refresh');
        return jsonResponse({'access': 'new_access', 'refresh': 'new_refresh'});
      });

      mainDio.httpClientAdapter = TestAdapter((options) async {
        mainAttempts++;
        if (mainAttempts == 1) {
          return jsonResponse({'error': 'Unauthorized'}, statusCode: 401);
        }
        expect(options.headers['Authorization'], 'Bearer new_access');
        return jsonResponse({'result': 'success'});
      });

      final response = await mainDio.get('/api/protected');

      expect(response.statusCode, 200);
      expect(response.data['result'], 'success');
      expect(refreshAttempts, 1);
      expect(mainAttempts, 2);
      expect(tokenStorage.access, 'new_access');
      expect(tokenStorage.refresh, 'new_refresh');
      expect(sessionExpiredCalled, isFalse);
    });

    test('single-flight: parallel 401s share a single refresh call', () async {
      int refreshCalls = 0;
      final refreshCompleter = Completer<void>();

      refreshDio.httpClientAdapter = TestAdapter((options) async {
        refreshCalls++;
        await refreshCompleter.future;
        return jsonResponse({
          'access': 'rotated_access',
          'refresh': 'rotated_refresh',
        });
      });

      int req1Attempts = 0;
      int req2Attempts = 0;

      mainDio.httpClientAdapter = TestAdapter((options) async {
        if (options.path == '/api/req1') {
          req1Attempts++;
          if (req1Attempts == 1) {
            return jsonResponse({'error': 'Unauthorized'}, statusCode: 401);
          }
          expect(options.headers['Authorization'], 'Bearer rotated_access');
          return jsonResponse({'id': 1});
        } else if (options.path == '/api/req2') {
          req2Attempts++;
          if (req2Attempts == 1) {
            return jsonResponse({'error': 'Unauthorized'}, statusCode: 401);
          }
          expect(options.headers['Authorization'], 'Bearer rotated_access');
          return jsonResponse({'id': 2});
        }
        return jsonResponse({});
      });

      // Launch both concurrently
      final future1 = mainDio.get('/api/req1');
      final future2 = mainDio.get('/api/req2');

      // Allow both requests to hit 401 and trigger refresh
      await Future.delayed(const Duration(milliseconds: 10));

      // Complete the single refresh call
      refreshCompleter.complete();

      final responses = await Future.wait([future1, future2]);

      expect(responses[0].data['id'], 1);
      expect(responses[1].data['id'], 2);
      expect(
        refreshCalls,
        1,
        reason: 'Refresh must be called only once for concurrent 401s',
      );
      expect(tokenStorage.access, 'rotated_access');
      expect(tokenStorage.refresh, 'rotated_refresh');
      expect(sessionExpiredCalled, isFalse);
    });

    test(
      'rejected refresh (401/400) clears storage and triggers logout callback',
      () async {
        refreshDio.httpClientAdapter = TestAdapter((options) async {
          return jsonResponse({
            'error': {'code': 401, 'message': 'Token is blacklisted'},
          }, statusCode: 401);
        });

        mainDio.httpClientAdapter = TestAdapter((options) async {
          return jsonResponse({'error': 'Unauthorized'}, statusCode: 401);
        });

        expect(
          () => mainDio.get('/api/protected'),
          throwsA(isA<DioException>()),
        );

        // Wait a tick for async error handler to finish
        await Future.delayed(const Duration(milliseconds: 20));

        expect(sessionExpiredCalled, isTrue);
        expect(tokenStorage.access, isNull);
        expect(tokenStorage.refresh, isNull);
      },
    );

    test(
      'network error during refresh does NOT log out or clear tokens',
      () async {
        refreshDio.httpClientAdapter = TestAdapter((options) async {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
            error: 'Connection timeout',
          );
        });

        mainDio.httpClientAdapter = TestAdapter((options) async {
          return jsonResponse({'error': 'Unauthorized'}, statusCode: 401);
        });

        await expectLater(
          () => mainDio.get('/api/protected'),
          throwsA(isA<DioException>()),
        );

        expect(
          sessionExpiredCalled,
          isFalse,
          reason: 'Network error must NOT log out',
        );
        expect(tokenStorage.access, 'initial_access');
        expect(tokenStorage.refresh, 'initial_refresh');
      },
    );

    test('no refresh attempt on login 401', () async {
      int refreshCalls = 0;

      refreshDio.httpClientAdapter = TestAdapter((options) async {
        refreshCalls++;
        return jsonResponse({'access': 'new', 'refresh': 'new'});
      });

      mainDio.httpClientAdapter = TestAdapter((options) async {
        return jsonResponse({
          'error': {'code': 401, 'message': 'Invalid credentials.'},
        }, statusCode: 401);
      });

      await expectLater(
        () => mainDio.post('/api/auth/login', data: {'email': 'a@b.com'}),
        throwsA(isA<DioException>()),
      );

      expect(refreshCalls, 0, reason: 'Login 401 must not attempt refresh');
      expect(sessionExpiredCalled, isFalse);
    });
  });
}
