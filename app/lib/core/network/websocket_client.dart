import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../../features/chat/domain/chat_models.dart';
import '../storage/token_storage.dart';
import 'backoff_strategy.dart';
import 'token_refresher.dart';
import 'websocket_channel_wrapper.dart';

enum WebSocketConnectionState {
  connecting,
  connected,
  waitingToRetry,
  serverWaking,
}

typedef WebSocketConnector =
    Future<WebSocketChannelWrapper> Function(
      Uri uri, {
      Map<String, dynamic>? headers,
      Duration? pingInterval,
      Duration? connectTimeout,
    });

class ChatWebSocketClient {
  ChatWebSocketClient({
    required this.wsUri,
    required this.tokenStorage,
    required this.tokenRefresher,
    this.connector = IOWebSocketChannelWrapper.defaultConnector,
    BackoffStrategy? backoffStrategy,
    this.pingInterval = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 10),
    this.onSessionExpired,
  }) : backoffStrategy = backoffStrategy ?? BackoffStrategy();

  final Uri wsUri;
  final TokenStorage tokenStorage;
  final TokenRefresher tokenRefresher;
  final WebSocketConnector connector;
  final BackoffStrategy backoffStrategy;
  final Duration pingInterval;
  final Duration connectTimeout;
  final void Function()? onSessionExpired;

  WebSocketConnectionState _state = WebSocketConnectionState.waitingToRetry;
  WebSocketConnectionState get state => _state;

  final _stateController =
      StreamController<WebSocketConnectionState>.broadcast();
  Stream<WebSocketConnectionState> get stateStream => _stateController.stream;

  final _eventsController = StreamController<WsEnvelope>.broadcast();
  Stream<WsEnvelope> get incomingEvents => _eventsController.stream;

  WebSocketChannelWrapper? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _reconnectTimer;

  bool _isDisposed = false;
  bool _isForegrounded = true;
  bool _wasTokenJustRefreshed = false;
  int _consecutiveFailures = 0;

  static const List<String> _knownEventTypes = [
    'chat.send',
    'chat.ack',
    'chat.receive',
    'error',
  ];

  void _setState(WebSocketConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      if (!_stateController.isClosed) {
        _stateController.add(newState);
      }
    }
  }

  /// Initiates connection or reconnect.
  Future<void> connect() async {
    if (_isDisposed || !_isForegrounded) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    _setState(WebSocketConnectionState.connecting);

    final token = await tokenStorage.getAccessToken();
    if (token == null || token.isEmpty) {
      _setState(WebSocketConnectionState.waitingToRetry);
      return;
    }

    try {
      final channel = await connector(
        wsUri,
        headers: {'Authorization': 'Bearer $token'},
        pingInterval: pingInterval,
        connectTimeout: connectTimeout,
      );

      _channel = channel;
      _consecutiveFailures = 0;
      backoffStrategy.reset();
      _setState(WebSocketConnectionState.connected);

      _channelSub = channel.stream.listen(
        (data) {
          _wasTokenJustRefreshed = false;
          _onMessage(data);
        },
        onError: _onError,
        onDone: () => _onDone(channel),
        cancelOnError: true,
      );
    } catch (e) {
      _handleConnectError(e);
    }
  }

  void _handleConnectError(dynamic error) {
    _consecutiveFailures++;

    // Check if error represents handshake timeout or 503
    final isHandshakeTimeout =
        error is TimeoutException || error is SocketException;
    final is503 = error.toString().contains('503');

    if (isHandshakeTimeout || is503 || _consecutiveFailures >= 3) {
      _setState(WebSocketConnectionState.serverWaking);
    } else {
      _setState(WebSocketConnectionState.waitingToRetry);
    }

    _scheduleReconnect();
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;

    try {
      final json = jsonDecode(data);
      if (json is! Map<String, dynamic>) return;

      final envelope = WsEnvelope.fromJson(json);
      if (!_knownEventTypes.contains(envelope.type)) {
        // Safely ignore unknown event types
        return;
      }

      if (!_eventsController.isClosed) {
        _eventsController.add(envelope);
      }
    } catch (_) {
      // Safely ignore malformed data
    }
  }

  void _onError(dynamic error) {
    _scheduleReconnect();
  }

  Future<void> _onDone(WebSocketChannelWrapper channel) async {
    final closeCode = channel.closeCode;
    _channel = null;
    await _channelSub?.cancel();
    _channelSub = null;

    if (_isDisposed || !_isForegrounded) return;

    if (closeCode == 4401) {
      await _handle4401();
      return;
    }

    _consecutiveFailures++;
    if (_consecutiveFailures >= 3) {
      _setState(WebSocketConnectionState.serverWaking);
    } else {
      _setState(WebSocketConnectionState.waitingToRetry);
    }

    _scheduleReconnect();
  }

  Future<void> _handle4401() async {
    if (_wasTokenJustRefreshed) {
      // Fresh token also got 4401: server rejected refreshed token! Log out!
      await tokenStorage.clearTokens();
      onSessionExpired?.call();
      _setState(WebSocketConnectionState.waitingToRetry);
      return;
    }

    try {
      final newToken = await tokenRefresher.refreshToken();
      if (newToken != null && newToken.isNotEmpty) {
        _wasTokenJustRefreshed = true;
        // Reconnect immediately with refreshed token
        await connect();
      } else {
        await tokenStorage.clearTokens();
        onSessionExpired?.call();
        _setState(WebSocketConnectionState.waitingToRetry);
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 400 || code == 401) {
        await tokenStorage.clearTokens();
        onSessionExpired?.call();
        _setState(WebSocketConnectionState.waitingToRetry);
      } else {
        // Network error during refresh: keep retrying, do not log out
        _consecutiveFailures++;
        if (_consecutiveFailures >= 3) {
          _setState(WebSocketConnectionState.serverWaking);
        } else {
          _setState(WebSocketConnectionState.waitingToRetry);
        }
        _scheduleReconnect();
      }
    } catch (_) {
      _consecutiveFailures++;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed || !_isForegrounded) return;

    _reconnectTimer?.cancel();
    final delay = backoffStrategy.nextDelay();
    _reconnectTimer = Timer(delay, () {
      connect();
    });
  }

  /// Sends a WebSocket envelope frame.
  bool sendEnvelope(WsEnvelope envelope) {
    if (_state != WebSocketConnectionState.connected || _channel == null) {
      return false;
    }
    try {
      final jsonString = jsonEncode(envelope.toJson());
      _channel!.sink.add(jsonString);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Lifecycle: called when app moves to background.
  void onAppBackgrounded() {
    _isForegrounded = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channel?.close();
    _channel = null;
    _channelSub?.cancel();
    _channelSub = null;
    _setState(WebSocketConnectionState.waitingToRetry);
  }

  /// Lifecycle: called when app resumes to foreground.
  void onAppResumed() {
    if (!_isForegrounded) {
      _isForegrounded = true;
      connect();
    }
  }

  /// Closes socket and cancels reconnects (e.g. on logout).
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _channelSub?.cancel();
    _channelSub = null;
    await _channel?.close();
    _channel = null;
    _consecutiveFailures = 0;
    _wasTokenJustRefreshed = false;
    backoffStrategy.reset();
    _setState(WebSocketConnectionState.waitingToRetry);
  }

  void dispose() {
    _isDisposed = true;
    disconnect();
    _stateController.close();
    _eventsController.close();
  }
}
