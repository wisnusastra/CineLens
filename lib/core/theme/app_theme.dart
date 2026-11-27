import 'package:flutter/material.dart';

/// CineLens Pro Design System — Obsidian Matte × Brass Amber × Tabular Mono.
class AppTheme {
  AppTheme._();

  static const Color backgroundBlack = Color(0xFF08080A);
  static const Color surfaceDark = Color(0xFF111115);
  static const Color cardDark = Color(0xFF17171D);
  static const Color cinemaAmber = Color(0xFFE5A93B);
  static const Color cinemaRed = Color(0xFFFF453A);
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color hairline = Color(0x18FFFFFF);

  static TextStyle monoStyle({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: 'Menlo',
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
      );

  static ThemeData get darkCinemaTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundBlack,
      colorScheme: const ColorScheme.dark(
        primary: cinemaAmber,
        secondary: cinemaAmber,
        surface: surfaceDark,
        error: cinemaRed,
        onPrimary: Colors.black,
        onSurface: textPrimary,
      ),
      dividerColor: hairline,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        },
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surfaceDark,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Color(0x88000000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundBlack,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.4,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardDark,
        contentTextStyle: const TextStyle(
          color: textPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: hairline),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
