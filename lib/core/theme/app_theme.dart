import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color backgroundBlack = Color(0xFF0A0A0C);
  static const Color surfaceDark = Color(0xFF16161A);
  static const Color cinemaAmber = Color(0xFFE5A93B);
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFF8E8E93);

  static ThemeData get darkCinemaTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundBlack,
      colorScheme: const ColorScheme.dark(
        primary: cinemaAmber,
        secondary: cinemaAmber,
        surface: surfaceDark,
        onPrimary: Colors.black,
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
