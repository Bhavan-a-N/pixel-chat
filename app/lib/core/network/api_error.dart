import 'package:dio/dio.dart';

class ApiError implements Exception {
  const ApiError({
    required this.code,
    required this.message,
    this.details,
    this.isNetworkError = false,
  });

  final int code;
  final String message;
  final dynamic details;
  final bool isNetworkError;

  factory ApiError.fromJson(
    Map<String, dynamic> json, {
    int fallbackCode = 400,
  }) {
    if (json.containsKey('error') && json['error'] is Map<String, dynamic>) {
      final errorMap = json['error'] as Map<String, dynamic>;
      return ApiError(
        code: errorMap['code'] is int ? errorMap['code'] as int : fallbackCode,
        message: errorMap['message']?.toString() ?? 'An error occurred',
        details: errorMap['details'],
        isNetworkError: false,
      );
    }

    return ApiError(
      code: fallbackCode,
      message: json['message']?.toString() ?? 'An error occurred',
      details: json['details'] ?? json,
      isNetworkError: false,
    );
  }

  factory ApiError.fromDioException(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return ApiError(
        code: 0,
        message:
            'Unable to connect to server. Please check your connection and retry.',
        isNetworkError: true,
      );
    }

    final response = e.response;
    if (response != null && response.data is Map<String, dynamic>) {
      return ApiError.fromJson(
        response.data as Map<String, dynamic>,
        fallbackCode: response.statusCode ?? 500,
      );
    }

    return ApiError(
      code: response?.statusCode ?? 500,
      message:
          response?.statusMessage ??
          e.message ??
          'An unexpected error occurred.',
      isNetworkError: false,
    );
  }

  String get friendlyMessage {
    if (isNetworkError) {
      return message;
    }

    if (code == 401) {
      return 'Invalid credentials. Please try again.';
    }

    if (code == 429) {
      return 'Too many requests. Please slow down and wait a moment.';
    }

    if (details is Map) {
      final map = details as Map;
      final messages = <String>[];
      for (final entry in map.entries) {
        final val = entry.value;
        if (val is List && val.isNotEmpty) {
          messages.add(val.first.toString());
        } else if (val != null) {
          messages.add(val.toString());
        }
      }
      if (messages.isNotEmpty) {
        return messages.join('\n');
      }
    } else if (details is String && (details as String).isNotEmpty) {
      return details as String;
    }

    return message.isNotEmpty ? message : 'An unexpected error occurred.';
  }

  @override
  String toString() =>
      'ApiError(code: $code, message: $message, isNetwork: $isNetworkError)';
}
