import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

@immutable
class SirixTheme extends ThemeExtension<SirixTheme> {
  const SirixTheme({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceMuted,
    required this.glassFill,
    required this.glassStroke,
    required this.primary,
    required this.primaryBright,
    required this.secondary,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.warning,
    required this.error,
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceMuted;
  final Color glassFill;
  final Color glassStroke;
  final Color primary;
  final Color primaryBright;
  final Color secondary;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color warning;
  final Color error;

  static const dark = SirixTheme(
    background: Color(0xFF0C1117),
    surface: Color(0xFF121A22),
    surfaceRaised: Color(0xFF18222C),
    surfaceMuted: Color(0xFF21303B),
    glassFill: Color(0xA61A2430),
    glassStroke: Color(0x33D9FEE7),
    primary: Color(0xFF73F4A3),
    primaryBright: Color(0xFF00F58B),
    secondary: Color(0xFF8EE6FF),
    textPrimary: Color(0xFFF5FFF9),
    textSecondary: Color(0xFFBDD2C6),
    textMuted: Color(0xFF718697),
    warning: Color(0xFFFFC857),
    error: Color(0xFFFF7F8F),
  );

  @override
  ThemeExtension<SirixTheme> lerp(covariant ThemeExtension<SirixTheme>? other, double t) {
    if (other is! SirixTheme) {
      return this;
    }
    return SirixTheme(
      background: Color.lerp(background, other.background, t) ?? background,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t) ?? surfaceRaised,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t) ?? surfaceMuted,
      glassFill: Color.lerp(glassFill, other.glassFill, t) ?? glassFill,
      glassStroke: Color.lerp(glassStroke, other.glassStroke, t) ?? glassStroke,
      primary: Color.lerp(primary, other.primary, t) ?? primary,
      primaryBright: Color.lerp(primaryBright, other.primaryBright, t) ?? primaryBright,
      secondary: Color.lerp(secondary, other.secondary, t) ?? secondary,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t) ?? textPrimary,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t) ?? textSecondary,
      textMuted: Color.lerp(textMuted, other.textMuted, t) ?? textMuted,
      warning: Color.lerp(warning, other.warning, t) ?? warning,
      error: Color.lerp(error, other.error, t) ?? error,
    );
  }

  @override
  SirixTheme copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceMuted,
    Color? glassFill,
    Color? glassStroke,
    Color? primary,
    Color? primaryBright,
    Color? secondary,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? warning,
    Color? error,
  }) {
    return SirixTheme(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      glassFill: glassFill ?? this.glassFill,
      glassStroke: glassStroke ?? this.glassStroke,
      primary: primary ?? this.primary,
      primaryBright: primaryBright ?? this.primaryBright,
      secondary: secondary ?? this.secondary,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      warning: warning ?? this.warning,
      error: error ?? this.error,
    );
  }
}

extension SirixThemeContext on BuildContext {
  SirixTheme get sirix => Theme.of(this).extension<SirixTheme>() ?? SirixTheme.dark;
}

class AppTheme {
  AppTheme._();

  static ThemeData darkSirix() {
    const palette = SirixTheme.dark;
    final baseTextTheme = GoogleFonts.interTextTheme(
      Typography.whiteCupertino.apply(
        bodyColor: palette.textPrimary,
        displayColor: palette.textPrimary,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: palette.background,
      colorScheme: ColorScheme.dark(
        primary: palette.primary,
        secondary: palette.secondary,
        surface: palette.surface,
        error: palette.error,
        onPrimary: const Color(0xFF06140D),
        onSecondary: const Color(0xFF08161A),
        onSurface: palette.textPrimary,
        onError: Colors.white,
      ),
      extensions: const [palette],
      textTheme: baseTextTheme.copyWith(
        headlineLarge: GoogleFonts.spaceGrotesk(
          textStyle: baseTextTheme.headlineLarge,
          fontWeight: FontWeight.w700,
          color: palette.textPrimary,
        ),
        headlineMedium: GoogleFonts.spaceGrotesk(
          textStyle: baseTextTheme.headlineMedium,
          fontWeight: FontWeight.w700,
          color: palette.textPrimary,
        ),
        titleLarge: GoogleFonts.spaceGrotesk(
          textStyle: baseTextTheme.titleLarge,
          fontWeight: FontWeight.w600,
          color: palette.textPrimary,
        ),
        bodyMedium: GoogleFonts.inter(
          textStyle: baseTextTheme.bodyMedium,
          color: palette.textPrimary,
        ),
        bodySmall: GoogleFonts.inter(
          textStyle: baseTextTheme.bodySmall,
          color: palette.textSecondary,
        ),
        labelMedium: GoogleFonts.inter(
          textStyle: baseTextTheme.labelMedium,
          fontWeight: FontWeight.w600,
          color: palette.textPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceMuted.withValues(alpha: 0.8),
        hintStyle: TextStyle(color: palette.textMuted),
        labelStyle: TextStyle(color: palette.textSecondary),
        prefixIconColor: palette.textMuted,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: palette.glassStroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: palette.secondary, width: 1.2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: palette.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: palette.error, width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: palette.glassStroke),
        ),
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: palette.glassStroke),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: palette.textPrimary,
        unselectedLabelColor: palette.textMuted,
        indicator: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: palette.primaryBright, width: 2),
          ),
        ),
      ),
      dividerColor: palette.glassStroke,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          textStyle: baseTextTheme.titleLarge,
          fontWeight: FontWeight.w700,
          color: palette.textPrimary,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface.withValues(alpha: 0.96),
        indicatorColor: palette.primary.withValues(alpha: 0.16),
        labelTextStyle: WidgetStatePropertyAll(
          GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  static ThemeData light() => darkSirix();

  static BoxDecoration glassDecoration(
    BuildContext context, {
    double radius = 28,
    Color? fillColor,
    Border? border,
  }) {
    final palette = context.sirix;
    return BoxDecoration(
      color: fillColor ?? palette.glassFill,
      borderRadius: BorderRadius.circular(radius),
      border: border ?? Border.all(color: palette.glassStroke),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.22),
          blurRadius: 36,
          offset: const Offset(0, 18),
        ),
      ],
    );
  }
}
