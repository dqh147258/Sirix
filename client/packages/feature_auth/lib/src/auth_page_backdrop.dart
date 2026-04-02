part of 'auth_page.dart';

class _DesktopAuthBlueprintBackdrop extends StatelessWidget {
  const _DesktopAuthBlueprintBackdrop();

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _DotGridPainter(color: Colors.white.withValues(alpha: 0.05)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(28),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: palette.surface.withValues(alpha: 0.52),
                      borderRadius: BorderRadius.circular(38),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 7,
                  child: Column(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.surface.withValues(alpha: 0.44),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                        ),
                        child: const SizedBox(height: 86),
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.36),
                            borderRadius: BorderRadius.circular(38),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              children: [
                                Row(
                                  children: List.generate(
                                    4,
                                    (index) => Expanded(
                                      child: Padding(
                                        padding: EdgeInsets.only(right: index == 3 ? 0 : 16),
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: palette.surfaceRaised.withValues(alpha: 0.78),
                                            borderRadius: BorderRadius.circular(22),
                                          ),
                                          child: const SizedBox(height: 120),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Expanded(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: palette.background.withValues(alpha: 0.72),
                                      borderRadius: BorderRadius.circular(30),
                                      border: Border.all(color: palette.glassStroke),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthBackdrop extends StatelessWidget {
  const _AuthBackdrop();

  @override
  Widget build(BuildContext context) {
    final palette = context.freeloom;

    return Stack(
      children: [
        Positioned(
          top: -80,
          right: -40,
          child: _GlowOrb(
            color: palette.primaryBright.withValues(alpha: 0.13),
            size: 260,
          ),
        ),
        Positioned(
          left: -100,
          bottom: 80,
          child: _GlowOrb(
            color: palette.secondary.withValues(alpha: 0.12),
            size: 240,
          ),
        ),
      ],
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size),
        boxShadow: [
          BoxShadow(
            color: color,
            blurRadius: size * 0.45,
            spreadRadius: 10,
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  const _DotGridPainter({
    required this.color,
  });

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double x = 12; x < size.width; x += 18) {
      for (double y = 12; y < size.height; y += 18) {
        canvas.drawCircle(Offset(x, y), 0.9, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter oldDelegate) => oldDelegate.color != color;
}
