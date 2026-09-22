import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_chat/core/network/backoff_strategy.dart';

class DeterministicRandom implements Random {
  DeterministicRandom(this.fixedValue);
  final double fixedValue;

  @override
  double nextDouble() => fixedValue;

  @override
  bool nextBool() => true;

  @override
  int nextInt(int max) => 0;
}

void main() {
  group('BackoffStrategy', () {
    test('grows exponentially, caps at maxDelay, and resets on success', () {
      // With jitterFactor = 0, growth is purely initialDelay * 2^attempt
      final backoff = BackoffStrategy(
        initialDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 30),
        multiplier: 2.0,
        jitterFactor: 0.0,
      );

      expect(backoff.attempts, 0);

      // Attempt 0: 1s
      expect(backoff.nextDelay(), const Duration(seconds: 1));
      expect(backoff.attempts, 1);

      // Attempt 1: 2s
      expect(backoff.nextDelay(), const Duration(seconds: 2));
      expect(backoff.attempts, 2);

      // Attempt 2: 4s
      expect(backoff.nextDelay(), const Duration(seconds: 4));
      expect(backoff.attempts, 3);

      // Attempt 3: 8s
      expect(backoff.nextDelay(), const Duration(seconds: 8));

      // Attempt 4: 16s
      expect(backoff.nextDelay(), const Duration(seconds: 16));

      // Attempt 5: capped at 30s
      expect(backoff.nextDelay(), const Duration(seconds: 30));

      // Attempt 6: still capped at 30s
      expect(backoff.nextDelay(), const Duration(seconds: 30));

      // Reset
      backoff.reset();
      expect(backoff.attempts, 0);
      expect(backoff.nextDelay(), const Duration(seconds: 1));
    });

    test('applies jitter within bounds', () {
      final maxRandom = DeterministicRandom(1.0); // max positive jitter
      final backoffMax = BackoffStrategy(
        initialDelay: const Duration(seconds: 10),
        maxDelay: const Duration(seconds: 30),
        jitterFactor: 0.2,
        random: maxRandom,
      );

      // 10s + 20% = 12s
      expect(backoffMax.nextDelay(), const Duration(seconds: 12));

      final minRandom = DeterministicRandom(0.0); // max negative jitter
      final backoffMin = BackoffStrategy(
        initialDelay: const Duration(seconds: 10),
        maxDelay: const Duration(seconds: 30),
        jitterFactor: 0.2,
        random: minRandom,
      );

      // 10s - 20% = 8s
      expect(backoffMin.nextDelay(), const Duration(seconds: 8));
    });
  });
}
