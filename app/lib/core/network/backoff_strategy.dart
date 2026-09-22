import 'dart:math';

/// Exponential backoff strategy with jitter and maximum delay cap.
class BackoffStrategy {
  BackoffStrategy({
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
    this.jitterFactor = 0.2,
    Random? random,
  }) : _random = random ?? Random();

  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;
  final double jitterFactor;
  final Random _random;

  int _attempts = 0;

  int get attempts => _attempts;

  /// Returns the next delay duration and increments the attempt counter.
  Duration nextDelay() {
    final expMs = initialDelay.inMilliseconds * pow(multiplier, _attempts);
    final cappedMs = min(expMs, maxDelay.inMilliseconds.toDouble());

    // Apply jitter: +/- (jitterFactor * cappedMs)
    double jitter = 0.0;
    if (jitterFactor > 0) {
      final maxJitter = cappedMs * jitterFactor;
      jitter = (_random.nextDouble() * 2 - 1) * maxJitter;
    }

    final finalMs = max(
      0.0,
      min(cappedMs + jitter, maxDelay.inMilliseconds.toDouble()),
    );

    _attempts++;
    return Duration(milliseconds: finalMs.round());
  }

  /// Resets the attempt counter on successful connection.
  void reset() {
    _attempts = 0;
  }
}
