import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pixel_chat/core/network/backoff_strategy.dart';
import 'package:pixel_chat/core/network/token_refresher.dart';
import 'package:pixel_chat/core/network/websocket_channel_wrapper.dart';
import 'package:pixel_chat/core/network/websocket_client.dart';
import 'package:pixel_chat/core/storage/token_storage.dart';
import 'package:pixel_chat/features/chat/domain/chat_models.dart';

class MockTokenStorage extends Mock implements TokenStorage {}

class MockTokenRefresher extends Mock implements TokenRefresher {}

class _FakeSink implements StreamSink<dynamic> {
  _FakeSink(this.sent);
  final List<dynamic> sent;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) => Future.value();

  @override
  Future close() => Future.value();

  @override
  Future get done => Future.value();
}

class FakeWebSocketChannelWrapper implements WebSocketChannelWrapper {
  FakeWebSocketChannelWrapper() {
    sink = _FakeSink(sentMessages);
  }

  final StreamController<dynamic> incomingController =
      StreamController<dynamic>.broadcast();
  final List<dynamic> sentMessages = [];
  final Completer<void> readyCompleter = Completer<void>();
  @override
  late final StreamSink<dynamic> sink;

  int? _closeCode;
  String? _closeReason;

  @override
  Stream<dynamic> get stream => incomingController.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  Future<void> get ready => readyCompleter.future;

  @override
  Future<void> close([int? code, String? reason]) async {
    _closeCode = code;
    _closeReason = reason;
    await incomingController.close();
  }

  void completeReady() {
    if (!readyCompleter.isCompleted) {
      readyCompleter.complete();
    }
  }

  void simulateClose(int code, [String? reason]) {
    _closeCode = code;
    _closeReason = reason;
    incomingController.close();
  }

  void emit(dynamic data) {
    incomingController.add(data);
  }
}

void main() {
  late MockTokenStorage tokenStorage;
  late MockTokenRefresher tokenRefresher;
  late Uri wsUri;
  late List<FakeWebSocketChannelWrapper> createdChannels;
  late Map<String, dynamic>? lastHeaders;
  bool sessionExpiredCalled = false;

  setUp(() {
    tokenStorage = MockTokenStorage();
    tokenRefresher = MockTokenRefresher();
    wsUri = Uri.parse('ws://localhost:8000/ws/chat/');
    createdChannels = [];
    lastHeaders = null;
    sessionExpiredCalled = false;

    when(
      () => tokenStorage.getAccessToken(),
    ).thenAnswer((_) async => 'access-123');
    when(() => tokenStorage.clearTokens()).thenAnswer((_) async {});
  });

  Future<WebSocketChannelWrapper> fakeConnector(
    Uri uri, {
    Map<String, dynamic>? headers,
    Duration? pingInterval,
    Duration? connectTimeout,
  }) async {
    lastHeaders = headers;
    final ch = FakeWebSocketChannelWrapper();
    createdChannels.add(ch);
    ch.completeReady();
    return ch;
  }

  test('connects with Authorization header and receives envelope', () async {
    final client = ChatWebSocketClient(
      wsUri: wsUri,
      tokenStorage: tokenStorage,
      tokenRefresher: tokenRefresher,
      connector: fakeConnector,
      onSessionExpired: () => sessionExpiredCalled = true,
    );

    expect(client.state, WebSocketConnectionState.waitingToRetry);

    await client.connect();

    expect(client.state, WebSocketConnectionState.connected);
    expect(lastHeaders?['Authorization'], 'Bearer access-123');
    expect(createdChannels.length, 1);

    // Listen to events
    final events = <WsEnvelope>[];
    client.incomingEvents.listen(events.add);

    // Emit known event
    createdChannels.first.emit(
      '{"v":1,"type":"chat.receive","client_id":"c1","payload":{"body":"hello"}}',
    );
    await pumpEventQueue();

    expect(events.length, 1);
    expect(events.first.type, 'chat.receive');
    expect(events.first.clientId, 'c1');
    expect(events.first.payload['body'], 'hello');

    // Emit unknown event: safely ignored
    createdChannels.first.emit('{"v":1,"type":"unknown.event","payload":{}}');
    await pumpEventQueue();
    expect(events.length, 1); // No new event added

    client.dispose();
  });

  test(
    '4401 triggers single-flight refresh then reconnects with new token',
    () async {
      when(
        () => tokenRefresher.refreshToken(),
      ).thenAnswer((_) async => 'fresh-access-456');

      final client = ChatWebSocketClient(
        wsUri: wsUri,
        tokenStorage: tokenStorage,
        tokenRefresher: tokenRefresher,
        connector: fakeConnector,
        onSessionExpired: () => sessionExpiredCalled = true,
      );

      await client.connect();
      expect(client.state, WebSocketConnectionState.connected);

      // Simulate 4401 close
      when(
        () => tokenStorage.getAccessToken(),
      ).thenAnswer((_) async => 'fresh-access-456');
      createdChannels.first.simulateClose(4401);
      await pumpEventQueue();

      // Verify tokenRefresher was called and a 2nd channel was created with the new token
      verify(() => tokenRefresher.refreshToken()).called(1);
      expect(createdChannels.length, 2);
      expect(lastHeaders?['Authorization'], 'Bearer fresh-access-456');
      expect(sessionExpiredCalled, false);

      client.dispose();
    },
  );

  test('fresh-token 4401 triggers logout immediately without loop', () async {
    when(
      () => tokenRefresher.refreshToken(),
    ).thenAnswer((_) async => 'fresh-access-456');

    final client = ChatWebSocketClient(
      wsUri: wsUri,
      tokenStorage: tokenStorage,
      tokenRefresher: tokenRefresher,
      connector: fakeConnector,
      onSessionExpired: () => sessionExpiredCalled = true,
    );

    await client.connect();

    // 1st close with 4401 -> triggers refresh
    when(
      () => tokenStorage.getAccessToken(),
    ).thenAnswer((_) async => 'fresh-access-456');
    createdChannels[0].simulateClose(4401);
    await pumpEventQueue();

    expect(createdChannels.length, 2);
    expect(sessionExpiredCalled, false);

    // 2nd close immediately with 4401 while on the fresh token -> must log out!
    createdChannels[1].simulateClose(4401);
    await pumpEventQueue();

    expect(sessionExpiredCalled, true);
    verify(() => tokenStorage.clearTokens()).called(1);
    // No third connection attempt
    expect(createdChannels.length, 2);

    client.dispose();
  });

  test('rejected refresh logs out and clears storage', () async {
    final dioError = DioException(
      requestOptions: RequestOptions(path: '/api/auth/refresh'),
      response: Response(
        statusCode: 401,
        requestOptions: RequestOptions(path: '/api/auth/refresh'),
      ),
    );
    when(() => tokenRefresher.refreshToken()).thenThrow(dioError);

    final client = ChatWebSocketClient(
      wsUri: wsUri,
      tokenStorage: tokenStorage,
      tokenRefresher: tokenRefresher,
      connector: fakeConnector,
      onSessionExpired: () => sessionExpiredCalled = true,
    );

    await client.connect();
    createdChannels.first.simulateClose(4401);
    await pumpEventQueue();

    expect(sessionExpiredCalled, true);
    verify(() => tokenStorage.clearTokens()).called(1);

    client.dispose();
  });

  test(
    'network error during refresh keeps retrying and does NOT log out',
    () async {
      final networkError = DioException(
        requestOptions: RequestOptions(path: '/api/auth/refresh'),
        type: DioExceptionType.connectionTimeout,
      );
      when(() => tokenRefresher.refreshToken()).thenThrow(networkError);

      final client = ChatWebSocketClient(
        wsUri: wsUri,
        tokenStorage: tokenStorage,
        tokenRefresher: tokenRefresher,
        connector: fakeConnector,
        backoffStrategy: BackoffStrategy(
          initialDelay: const Duration(milliseconds: 10),
          maxDelay: const Duration(milliseconds: 50),
          jitterFactor: 0,
        ),
        onSessionExpired: () => sessionExpiredCalled = true,
      );

      await client.connect();
      createdChannels.first.simulateClose(4401);
      await pumpEventQueue();

      expect(sessionExpiredCalled, false);
      verifyNever(() => tokenStorage.clearTokens());

      client.dispose();
    },
  );

  test('defines server waking on handshake timeout or 3+ failures', () async {
    int attempts = 0;
    Future<WebSocketChannelWrapper> failingConnector(
      Uri uri, {
      Map<String, dynamic>? headers,
      Duration? pingInterval,
      Duration? connectTimeout,
    }) async {
      attempts++;
      if (attempts == 1) {
        throw TimeoutException('Handshake timeout');
      }
      throw Exception('Socket error');
    }

    final client = ChatWebSocketClient(
      wsUri: wsUri,
      tokenStorage: tokenStorage,
      tokenRefresher: tokenRefresher,
      connector: failingConnector,
      backoffStrategy: BackoffStrategy(
        initialDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 50),
        jitterFactor: 0,
      ),
    );

    // Attempt 1: Handshake timeout -> serverWaking
    await client.connect();
    expect(client.state, WebSocketConnectionState.serverWaking);

    client.dispose();
  });

  test('background closes socket and resume reconnects', () async {
    final client = ChatWebSocketClient(
      wsUri: wsUri,
      tokenStorage: tokenStorage,
      tokenRefresher: tokenRefresher,
      connector: fakeConnector,
    );

    await client.connect();
    expect(client.state, WebSocketConnectionState.connected);
    expect(createdChannels.length, 1);

    // Background app
    client.onAppBackgrounded();
    expect(client.state, WebSocketConnectionState.waitingToRetry);

    // Resume app
    client.onAppResumed();
    await pumpEventQueue();
    expect(client.state, WebSocketConnectionState.connected);
    expect(createdChannels.length, 2);

    client.dispose();
  });
}
