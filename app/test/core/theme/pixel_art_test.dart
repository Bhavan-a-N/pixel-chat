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

    test('fromSeed produces consistent fixtures', () {
      final id1 = CritterIdentity.fromSeed('550c9958-5749-482b-eb7c-14eb124141ab');
      expect(id1.type, CritterType.cat);
      // Pal: 2, Ring: 2

      final id2 = CritterIdentity.fromSeed('9b35fca1-c30d-4417-ff42-1af3fb09d4a2');
      expect(id2.type, CritterType.fox);
      // Pal: 0, Ring: 1

      final id3 = CritterIdentity.fromSeed('0f07c60f-dbd8-43d1-ff23-5c2956009e11');
      expect(id3.type, CritterType.bear);
      // Pal: 2, Ring: 2
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
