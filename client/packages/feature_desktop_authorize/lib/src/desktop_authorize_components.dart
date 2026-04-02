part of 'desktop_authorize_page.dart';

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.title,
    required this.value,
    required this.active,
    this.trailing,
  });

  final String title;
  final String value;
  final bool active;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return SizedBox(
      width: 280,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF151A1F).withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                        fontFamily: 'JetBrains Mono',
                      ),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? palette.primaryBright : palette.textMuted,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 8),
                Text(active ? context.l10n.active : context.l10n.idle),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  fontFamily: 'JetBrains Mono',
                ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _AuthorizeModal extends StatelessWidget {
  const _AuthorizeModal({
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  final PendingAuthorizeRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    final l10n = context.l10n;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.securityProtocolActive,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.primaryBright,
                          fontFamily: 'JetBrains Mono',
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.incomingConnectionRequest,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 28),
                  ),
                ],
              ),
            ),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.surfaceRaised,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.wifi_tethering_rounded, color: palette.secondary),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: palette.primaryBright.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.phone_iphone_rounded, color: palette.primaryBright),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.sourceDeviceLabel,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: palette.textMuted,
                                fontFamily: 'JetBrains Mono',
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(request.requester, style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _DetailGrid(request: request),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.block_rounded),
                label: Text(l10n.reject),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: onApprove,
                style: FilledButton.styleFrom(
                  backgroundColor: palette.primary,
                  foregroundColor: const Color(0xFF07120D),
                  minimumSize: const Size.fromHeight(50),
                ),
                icon: const Icon(Icons.verified_user_rounded),
                label: Text(l10n.authorizeAccess),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.requestMetaLeft(request.sessionId),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                    ),
              ),
            ),
            Expanded(
              child: Text(
                l10n.requestMetaRight,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                      fontFamily: 'JetBrains Mono',
                    ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({
    required this.request,
  });

  final PendingAuthorizeRequest request;

  @override
  Widget build(BuildContext context) {
    final items = [
      (context.l10n.ipAddressLabel, '192.168.1.104'),
      (context.l10n.protocolLabel, 'AES-256-GCM'),
      (context.l10n.timestampLabel, '2026-04-02 14:02:11'),
      (context.l10n.locationLabel, request.deviceName),
    ];

    return Wrap(
      spacing: 28,
      runSpacing: 16,
      children: [
        for (final item in items)
          SizedBox(
            width: 170,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.$1,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.sirix.textMuted,
                        fontFamily: 'JetBrains Mono',
                      ),
                ),
                const SizedBox(height: 4),
                Text(item.$2, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
      ],
    );
  }
}

class _TechGridPainter extends CustomPainter {
  const _TechGridPainter({
    required this.color,
  });

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TechGridPainter oldDelegate) => oldDelegate.color != color;
}
