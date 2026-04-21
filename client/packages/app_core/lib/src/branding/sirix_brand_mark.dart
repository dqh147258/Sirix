import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shared Sirix brand mark inspired by the approved Sirius-like reference:
/// a compact dark plate, one large emerald diamond, one bright inner diamond,
/// and three luminous orbit nodes representing the backend, desktop, and
/// mobile/client parts of the Sirix system.
class SirixBrandMark extends StatelessWidget {
  const SirixBrandMark({
    super.key,
    this.size = 32,
    this.showPlate = false,
  });

  final double size;
  final bool showPlate;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SirixBrandMarkPainter(
          palette: palette,
          showPlate: showPlate,
        ),
      ),
    );
  }
}

class _SirixBrandMarkPainter extends CustomPainter {
  const _SirixBrandMarkPainter({
    required this.palette,
    required this.showPlate,
  });

  final SirixTheme palette;
  final bool showPlate;

  @override
  void paint(Canvas canvas, Size size) {
    final shortestSide = math.min(size.width, size.height);
    final plateRect = Offset.zero & size;
    final center = size.center(Offset.zero);

    if (showPlate) {
      final radius = Radius.circular(shortestSide * 0.24);
      canvas.drawRRect(
        RRect.fromRectAndRadius(plateRect, radius),
        Paint()..color = const Color(0xFF10161B),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(plateRect, radius),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: 0.10),
              palette.primaryBright.withValues(alpha: 0.10),
              Colors.black.withValues(alpha: 0.18),
            ],
          ).createShader(plateRect)
          ..style = PaintingStyle.stroke
          ..strokeWidth = shortestSide * 0.028,
      );
      canvas.drawCircle(
        Offset(size.width * 0.36, size.height * 0.34),
        shortestSide * 0.26,
        Paint()
          ..color = palette.primaryBright.withValues(alpha: 0.06)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            shortestSide * 0.09,
          ),
      );
    }

    final outerDiamondRadius = shortestSide * 0.27;
    final innerDiamondRadius = shortestSide * 0.102;
    final nodeRadius = shortestSide * 0.056;
    final connectorStrokeWidth = shortestSide * 0.036;
    final connectorPaint = Paint()
      ..color = const Color(0xFF214E44).withValues(alpha: 0.9)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = connectorStrokeWidth;

    final outerDiamond = Path()
      ..moveTo(center.dx, center.dy - outerDiamondRadius)
      ..lineTo(center.dx + outerDiamondRadius, center.dy)
      ..lineTo(center.dx, center.dy + outerDiamondRadius)
      ..lineTo(center.dx - outerDiamondRadius, center.dy)
      ..close();
    canvas.drawPath(
      outerDiamond,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF2E8B69),
            Color(0xFF1F5E4A),
            Color(0xFF143B31),
          ],
        ).createShader(outerDiamond.getBounds()),
    );
    canvas.drawPath(
      outerDiamond,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = shortestSide * 0.018,
    );

    final nodeOffsets = <Offset>[
      Offset(size.width * 0.23, size.height * 0.28),
      Offset(size.width * 0.77, size.height * 0.28),
      Offset(size.width * 0.23, size.height * 0.74),
    ];
    final connectorTargets = <Offset>[
      Offset(center.dx - outerDiamondRadius * 0.52, center.dy - outerDiamondRadius * 0.52),
      Offset(center.dx + outerDiamondRadius * 0.52, center.dy - outerDiamondRadius * 0.52),
      Offset(center.dx - outerDiamondRadius * 0.52, center.dy + outerDiamondRadius * 0.52),
    ];

    for (var index = 0; index < nodeOffsets.length; index++) {
      canvas.drawLine(nodeOffsets[index], connectorTargets[index], connectorPaint);
    }

    canvas.drawCircle(
      center,
      innerDiamondRadius * 1.7,
      Paint()
        ..color = palette.primaryBright.withValues(alpha: 0.18)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          shortestSide * 0.08,
        ),
    );

    final innerDiamond = Path()
      ..moveTo(center.dx, center.dy - innerDiamondRadius)
      ..lineTo(center.dx + innerDiamondRadius, center.dy)
      ..lineTo(center.dx, center.dy + innerDiamondRadius)
      ..lineTo(center.dx - innerDiamondRadius, center.dy)
      ..close();
    canvas.drawPath(
      innerDiamond,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.primaryBright,
            const Color(0xFF72F6C4),
          ],
        ).createShader(innerDiamond.getBounds()),
    );
    canvas.drawPath(
      innerDiamond,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = shortestSide * 0.014,
    );

    final nodeGlowPaint = Paint()
      ..color = palette.primaryBright.withValues(alpha: 0.22)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, shortestSide * 0.05);
    final nodePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFFB9FFE5),
          Color(0xFF7AF5C5),
        ],
      ).createShader(plateRect);
    final nodeStrokePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = shortestSide * 0.01;

    for (final offset in nodeOffsets) {
      canvas.drawCircle(offset, nodeRadius * 1.8, nodeGlowPaint);
      canvas.drawCircle(offset, nodeRadius, nodePaint);
      canvas.drawCircle(offset, nodeRadius, nodeStrokePaint);
    }

    canvas.drawCircle(
      center,
      shortestSide * 0.016,
      Paint()..color = const Color(0xFFE5FFF6),
    );
  }

  @override
  bool shouldRepaint(covariant _SirixBrandMarkPainter oldDelegate) {
    return oldDelegate.palette != palette || oldDelegate.showPlate != showPlate;
  }
}
