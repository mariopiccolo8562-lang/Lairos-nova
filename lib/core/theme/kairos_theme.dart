import 'dart:ui';

import 'package:flutter/material.dart';

/// Palette "Kairos Nova": nero profondo, ciano elettrico, viola plasma.
/// Pensata per OLED (neri veri = risparmio energia + contrasto) e per TV a 3 metri.
class KairosColors {
  static const Color bg = Color(0xFF050507);
  static const Color bgElevated = Color(0xFF0C0D12);
  static const Color surface = Color(0xFF12131A);
  static const Color surfaceHi = Color(0xFF1A1C25);
  static const Color line = Color(0x1AFFFFFF);

  static const Color cyan = Color(0xFF00E5FF);
  static const Color violet = Color(0xFF7C4DFF);
  static const Color magenta = Color(0xFFFF2ED1);
  static const Color lime = Color(0xFFB2FF59);
  static const Color amber = Color(0xFFFFC400);
  static const Color red = Color(0xFFFF3D5A);

  static const Color text = Color(0xFFF4F6FB);
  static const Color textDim = Color(0xFF9AA0B4);
  static const Color textMute = Color(0xFF5C6072);

  static const LinearGradient plasma = LinearGradient(
    colors: [cyan, violet, magenta],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroFade = LinearGradient(
    colors: [Color(0x00050507), Color(0xCC050507), bg],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.7, 1.0],
  );
}

class KairosTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    final scheme = const ColorScheme.dark(
      primary: KairosColors.cyan,
      onPrimary: Colors.black,
      secondary: KairosColors.violet,
      onSecondary: Colors.white,
      surface: KairosColors.surface,
      onSurface: KairosColors.text,
      error: KairosColors.red,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: KairosColors.bg,
      canvasColor: KairosColors.bg,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      textTheme: base.textTheme.apply(
        bodyColor: KairosColors.text,
        displayColor: KairosColors.text,
      ).copyWith(
        displayLarge: const TextStyle(
            fontSize: 56, fontWeight: FontWeight.w800, letterSpacing: -1.5),
        headlineMedium: const TextStyle(
            fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5),
        titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        labelSmall: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.8,
            color: KairosColors.textDim),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: KairosColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: KairosColors.line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: KairosColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: KairosColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: KairosColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: KairosColors.cyan, width: 1.5),
        ),
        hintStyle: const TextStyle(color: KairosColors.textMute),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: KairosColors.cyan,
          foregroundColor: Colors.black,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
        ),
      ),
      dividerColor: KairosColors.line,
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: KairosColors.surfaceHi,
        contentTextStyle: TextStyle(color: KairosColors.text),
        behavior: SnackBarBehavior.floating,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

/// Pannello "vetro": blur + bordo luminoso. Usato ovunque per il look futuristico.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.glow = false,
    this.opacity = 0.55,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final bool glow;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: KairosColors.surface.withOpacity(opacity),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: glow
                  ? KairosColors.cyan.withOpacity(0.6)
                  : KairosColors.line,
            ),
            boxShadow: glow
                ? [
                    BoxShadow(
                      color: KairosColors.cyan.withOpacity(0.25),
                      blurRadius: 28,
                      spreadRadius: -4,
                    )
                  ]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Testo con gradiente plasma (titoli, logo).
class PlasmaText extends StatelessWidget {
  const PlasmaText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => KairosColors.plasma.createShader(rect),
      blendMode: BlendMode.srcIn,
      child: Text(text, style: style),
    );
  }
}
