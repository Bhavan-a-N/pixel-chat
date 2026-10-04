import 'package:flutter/material.dart';
import '../../core/theme/critter_identity.dart';
import '../../core/theme/pixel_art.dart';

class PixelAvatar extends StatelessWidget {
  final String seed;
  final double size;

  const PixelAvatar({
    super.key,
    required this.seed,
    this.size = 40.0,
  });

  @override
  Widget build(BuildContext context) {
    final identity = CritterIdentity.fromSeed(seed);
    
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: identity.ringColor,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: PixelArt(
        grid: identity.grid,
        palette: identity.palette,
        size: size * 0.7, // Critter takes up 70% of the avatar circle
      ),
    );
  }
}
