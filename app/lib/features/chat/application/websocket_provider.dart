import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/env.dart';
import '../../../core/network/dio_provider.dart';
import '../../../core/network/websocket_channel_wrapper.dart';
import '../../../core/network/websocket_client.dart';
import '../../auth/application/auth_notifier.dart';
import '../../auth/application/auth_state.dart';

final webSocketConnectorProvider = Provider<WebSocketConnector>((ref) {
  return IOWebSocketChannelWrapper.defaultConnector;
});

final chatWebSocketClientProvider = Provider<ChatWebSocketClient>((ref) {
  final tokenStorage = ref.watch(tokenStorageProvider);
  final tokenRefresher = ref.watch(tokenRefresherProvider);
  final connector = ref.watch(webSocketConnectorProvider);

  final client = ChatWebSocketClient(
    wsUri: Uri.parse(AppEnv.wsChatEndpoint),
    tokenStorage: tokenStorage,
    tokenRefresher: tokenRefresher,
    connector: connector,
    onSessionExpired: () {
      final callback = ref.read(onSessionExpiredProvider);
      callback?.call();
    },
  );

  ref.onDispose(() {
    client.dispose();
  });

  return client;
});

class WebSocketStateNotifier extends Notifier<WebSocketConnectionState> {
  @override
  WebSocketConnectionState build() {
    final client = ref.watch(chatWebSocketClientProvider);
    final authState = ref.watch(authNotifierProvider);

    // The socket exists ONLY while authenticated.
    if (authState.status == AuthStatus.authenticated) {
      client.connect();
    } else {
      client.disconnect();
    }

    final sub = client.stateStream.listen((state) {
      this.state = state;
    });

    ref.onDispose(() {
      sub.cancel();
    });

    return client.state;
  }
}

final webSocketStateProvider =
    NotifierProvider<WebSocketStateNotifier, WebSocketConnectionState>(
      WebSocketStateNotifier.new,
    );

/// App lifecycle observer to pause/resume WebSocket on background/foreground.
class AppLifecycleManager extends WidgetsBindingObserver {
  AppLifecycleManager(this._ref) {
    WidgetsBinding.instance.addObserver(this);
  }

  final Ref _ref;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final client = _ref.read(chatWebSocketClientProvider);
    final authState = _ref.read(authNotifierProvider);

    if (authState.status != AuthStatus.authenticated) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      client.onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      client.onAppResumed();
    }
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}

final appLifecycleManagerProvider = Provider<AppLifecycleManager>((ref) {
  final manager = AppLifecycleManager(ref);
  ref.onDispose(manager.dispose);
  return manager;
});
