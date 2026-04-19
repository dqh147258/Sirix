import 'package:flutter/material.dart';

import 'package:app_core/app_core.dart';
import 'package:infra_api/infra_api.dart';

Future<T?> showAiSettingsDialog<T>(
  {required BuildContext context,
  required String title,
  String? subtitle,
  required Widget child,
  required List<Widget> actions,
  double width = 640,
}) {
  final palette = context.sirix;
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Container(
        constraints: BoxConstraints(maxWidth: width),
        decoration: BoxDecoration(
          color: palette.surfaceRaised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.glassStroke),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 40,
              offset: const Offset(0, 24),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                            color: palette.textPrimary,
                          ),
                        ),
                        if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2.0,
                              color: palette.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, color: palette.textMuted),
                    hoverColor: palette.surfaceMuted,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: palette.glassStroke),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    textTheme: Theme.of(context).textTheme.copyWith(
                          bodyLarge: TextStyle(
                            fontFamily: 'JetBrains Mono',
                            fontSize: 13,
                            color: palette.primaryBright.withValues(alpha: 0.9),
                            height: 1.5,
                          ),
                        ),
                    textSelectionTheme: TextSelectionThemeData(
                      cursorColor: palette.primaryBright,
                      selectionColor: palette.primaryBright.withValues(alpha: 0.3),
                      selectionHandleColor: palette.primaryBright,
                    ),
                    inputDecorationTheme: InputDecorationTheme(
                      filled: true,
                      fillColor: palette.surfaceMuted.withValues(alpha: 0.3),
                      labelStyle: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: palette.textMuted,
                      ),
                      hintStyle: TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontSize: 12,
                        color: palette.textMuted.withValues(alpha: 0.5),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: palette.glassStroke),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: palette.glassStroke),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: palette.primaryBright),
                      ),
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
            if (actions.isNotEmpty) ...[
              Divider(height: 1, color: palette.glassStroke),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                child: Theme(
                  data: Theme.of(context).copyWith(
                    filledButtonTheme: FilledButtonThemeData(
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.primaryBright,
                        foregroundColor: Colors.black, // High contrast text
                        textStyle: const TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                    textButtonTheme: TextButtonThemeData(
                      style: TextButton.styleFrom(
                        foregroundColor: palette.textSecondary,
                        textStyle: const TextStyle(
                          fontFamily: 'Inter',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions
                        .map((widget) => Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: widget,
                            ))
                        .toList(growable: false),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class AiSettingsCard extends StatelessWidget {
  const AiSettingsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
      ),
      child: child,
    );
  }
}

class AiSettingsSectionHeader extends StatelessWidget {
  const AiSettingsSectionHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontFamily: 'Space Grotesk',
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: palette.textMuted,
                      ),
                ),
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: 16),
            action!,
          ],
        ],
      ),
    );
  }
}

class AiSettingsEmptyState extends StatelessWidget {
  const AiSettingsEmptyState({
    super.key,
    required this.text,
  });

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return AiSettingsCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: palette.surfaceMuted.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.inbox_rounded, color: palette.textMuted, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

String approvalModeLabel(ApprovalMode mode) {
  return switch (mode) {
    ApprovalMode.allow => 'Allow',
    ApprovalMode.ask => 'Ask',
    ApprovalMode.deny => 'Deny',
  };
}

class ApprovalModeSegmentedControl extends StatelessWidget {
  const ApprovalModeSegmentedControl({
    super.key,
    required this.value,
    required this.onChanged,
    this.dense = false,
  });

  final ApprovalMode value;
  final ValueChanged<ApprovalMode> onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Container(
      padding: EdgeInsets.all(dense ? 4 : 5),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.glassStroke),
      ),
      child: Row(
        children: [
          for (final mode in ApprovalMode.values) ...[
            Expanded(
              child: _ApprovalModeSegment(
                mode: mode,
                selected: mode == value,
                dense: dense,
                onTap: () => onChanged(mode),
              ),
            ),
            if (mode != ApprovalMode.values.last)
              SizedBox(width: dense ? 4 : 5),
          ],
        ],
      ),
    );
  }
}

class _ApprovalModeSegment extends StatelessWidget {
  const _ApprovalModeSegment({
    required this.mode,
    required this.selected,
    required this.dense,
    required this.onTap,
  });

  final ApprovalMode mode;
  final bool selected;
  final bool dense;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 8 : 12,
            vertical: dense ? 9 : 11,
          ),
          decoration: BoxDecoration(
            color: selected
                ? palette.primaryBright.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? palette.primaryBright.withValues(alpha: 0.34)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _approvalModeIcon(mode),
                size: dense ? 15 : 16,
                color: selected ? palette.primaryBright : palette.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  approvalModeLabel(mode),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected ? palette.textPrimary : palette.textSecondary,
                        fontSize: dense ? 12 : null,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _approvalModeIcon(ApprovalMode mode) {
  return switch (mode) {
    ApprovalMode.allow => Icons.check_circle_outline_rounded,
    ApprovalMode.ask => Icons.help_outline_rounded,
    ApprovalMode.deny => Icons.block_rounded,
  };
}

class AiSettingsChip extends StatelessWidget {
  const AiSettingsChip({
    super.key,
    required this.label,
  });

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: palette.textSecondary,
              fontFamily: 'JetBrains Mono',
            ),
      ),
    );
  }
}

class AiSettingsToggleTile extends StatelessWidget {
  const AiSettingsToggleTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.width,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final palette = context.sirix;
    return Container(
      width: width ?? 320, // Provide a safe fallback width so Wrap doesn't throw if unbounded
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.glassStroke), // Add faint stroke like inputs
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: palette.textPrimary,
                      ),
                  softWrap: true,
                ),
                if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          color: palette.textMuted,
                        ),
                    softWrap: true,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: palette.primaryBright,
          ),
        ],
      ),
    );
  }
}

class AiSettingsFieldGroup extends StatelessWidget {
  const AiSettingsFieldGroup({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < children.length; index += 1) ...[
          children[index],
          if (index != children.length - 1) const SizedBox(height: 14),
        ],
      ],
    );
  }
}
