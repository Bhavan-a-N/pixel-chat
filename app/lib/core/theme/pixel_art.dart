import 'package:flutter/material.dart';

/// Renders a crisp 16x16 pixel art image using a CustomPainter.
/// It uses no anti-aliasing to keep edges perfectly sharp.
class PixelArt extends StatelessWidget {
  final List<String> grid;
  final Map<String, Color> palette;
  final double size;

  const PixelArt({
    super.key,
    required this.grid,
    required this.palette,
    this.size = 64.0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _PixelArtPainter(
          grid: grid,
          palette: palette,
        ),
      ),
    );
  }
}

class _PixelArtPainter extends CustomPainter {
  final List<String> grid;
  final Map<String, Color> palette;

  _PixelArtPainter({
    required this.grid,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (grid.isEmpty) return;
    
    final int rows = grid.length;
    final int cols = grid[0].length;
    final double pixelWidth = size.width / cols;
    final double pixelHeight = size.height / rows;

    final Paint paint = Paint()
      ..isAntiAlias = false // Force perfectly crisp edges
      ..style = PaintingStyle.fill;

    for (int y = 0; y < rows; y++) {
      final rowStr = grid[y];
      for (int x = 0; x < cols; x++) {
        if (x >= rowStr.length) break;
        final char = rowStr[x];
        
        if (char != '.' && palette.containsKey(char)) {
          paint.color = palette[char]!;
          // Using slightly overlapping rects (e.g. +0.2) or exactly the pixel bounds?
          // Without anti-aliasing, exact bounds are perfect.
          canvas.drawRect(
            Rect.fromLTWH(
              x * pixelWidth,
              y * pixelHeight,
              pixelWidth,
              pixelHeight,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PixelArtPainter oldDelegate) {
    return oldDelegate.grid != grid || oldDelegate.palette != palette;
  }
}
