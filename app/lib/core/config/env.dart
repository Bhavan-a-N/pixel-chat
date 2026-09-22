class AppEnv {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static String get wsBaseUrl {
    if (apiBaseUrl.startsWith('https://')) {
      return 'wss://${apiBaseUrl.substring(8)}';
    } else if (apiBaseUrl.startsWith('http://')) {
      return 'ws://${apiBaseUrl.substring(7)}';
    }
    return apiBaseUrl;
  }

  static String get wsChatEndpoint => '$wsBaseUrl/ws/chat/';
}
