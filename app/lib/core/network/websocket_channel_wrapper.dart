import 'dart:async';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Abstraction over [WebSocketChannel] allowing test fakes and custom sockets.
abstract class WebSocketChannelWrapper {
  Stream<dynamic> get stream;
  StreamSink<dynamic> get sink;
  int? get closeCode;
  String? get closeReason;
  Future<void> get ready;
  Future<void> close([int? code, String? reason]);
}

/// Production implementation of [WebSocketChannelWrapper] wrapping [IOWebSocketChannel].
class IOWebSocketChannelWrapper implements WebSocketChannelWrapper {
  IOWebSocketChannelWrapper(this._channel);

  final IOWebSocketChannel _channel;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  StreamSink<dynamic> get sink => _channel.sink;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Future<void> close([int? code, String? reason]) =>
      _channel.sink.close(code, reason);

  /// Default connector using [IOWebSocketChannel.connect].
  static Future<WebSocketChannelWrapper> defaultConnector(
    Uri uri, {
    Map<String, dynamic>? headers,
    Duration? pingInterval,
    Duration? connectTimeout,
  }) async {
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: headers,
      pingInterval: pingInterval,
      connectTimeout: connectTimeout,
    );
    // Await ready to confirm handshake completed within connectTimeout
    await channel.ready;
    return IOWebSocketChannelWrapper(channel);
  }
}
