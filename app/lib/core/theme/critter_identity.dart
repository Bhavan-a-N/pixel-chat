import 'package:flutter/material.dart';
import 'app_theme.dart';
import 'pixel_assets.dart';

enum CritterType { cat, fox, bear }

class CritterIdentity {
  final CritterType type;
  final Map<String, Color> palette;
  final Color ringColor;

  const CritterIdentity({
    required this.type,
    required this.palette,
    required this.ringColor,
  });

  static CritterIdentity fromSeed(String seed) {
    // Simple djb2 hash to avoid crypto dependency and ensure cross-session determinism
    int hash = 5381;
    for (int i = 0; i < seed.length; i++) {
      hash = ((hash << 5) + hash) + seed.codeUnitAt(i);
    }
    hash = hash.abs();
    
    // Use distinct modulo chunks to ensure good distribution
    final int typeInt = hash % 3;
    final int paletteInt = (hash ~/ 3) % 3;
    final int ringInt = (hash ~/ 9) % 3;

    final type = CritterType.values[typeInt];
    final selectedPalette = _getPalette(type, paletteInt);

    final List<Color> ringColors = [
      AppColors.primaryContainer,
      AppColors.success,
      AppColors.primaryContainer,
    ];
    final ringColor = ringColors[ringInt];

    return CritterIdentity(
      type: type,
      palette: selectedPalette,
      ringColor: ringColor,
    );
  }

  List<String> get grid {
    switch (type) {
      case CritterType.cat: return PixelAssets.cat;
      case CritterType.fox: return PixelAssets.fox;
      case CritterType.bear: return PixelAssets.bear;
    }
  }

  static Map<String, Color> _getPalette(CritterType type, int index) {
    // 1: outline, 2: base, 3: highlight/belly, 4: eyes/nose
    final outline = AppColors.onBackground;
    final features = AppColors.onBackground;

    switch (index) {
      case 0: // Orange / Warm
        return {
          '1': outline,
          '2': const Color(0xFFF6AD55), 
          '3': const Color(0xFFFFEAC1), 
          '4': features,
        };
      case 1: // Mint / Cool
        return {
          '1': outline,
          '2': const Color(0xFF68D391), 
          '3': const Color(0xFFE6FFFA), 
          '4': features,
        };
      case 2: // Blue / Calm
      default:
        return {
          '1': outline,
          '2': const Color(0xFF63B3ED), 
          '3': const Color(0xFFEBF8FF), 
          '4': features,
        };
    }
  }
}
