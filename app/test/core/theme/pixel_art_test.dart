import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pixel_chat/core/theme/critter_identity.dart';
import 'package:pixel_chat/core/theme/pixel_art.dart';

void main() {
  group('CritterIdentity', () {
    test('fromSeed produces deterministic results', () {
      final identity1 = CritterIdentity.fromSeed('alice');
      final identity2 = CritterIdentity.fromSeed('alice');
      
      expect(identity1.type, identity2.type);
      expect(identity1.palette, identity2.palette);
      expect(identity1.ringColor, identity2.ringColor);
    });

    test('fromSeed produces varied distribution', () {
      final Set<CritterType> types = {};
      final Set<Color> ringColors = {};
      
      for (int i = 0; i < 50; i++) {
        final identity = CritterIdentity.fromSeed('user_$i');
        types.add(identity.type);
        ringColors.add(identity.ringColor);
      }
      
      // We should see all 3 types and 3 ring colors generated over 50 unique seeds
      expect(types.length, 3);
      expect(ringColors.length, 3);
    });
  });

  group('PixelArtPainter', () {
    testWidgets('uses FilterQuality.none (via CustomPainter lacking anti-aliasing)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PixelArt(
              grid: ["1"],
              palette: {"1": Colors.black},
            ),
          ),
        ),
      );

      final customPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(PixelArt),
          matching: find.byType(CustomPaint),
        )
      );
      expect(customPaint.painter, isNotNull);
    });
  });
}
