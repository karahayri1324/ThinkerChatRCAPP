import 'package:flutter/material.dart';

class TokyoNight {
  static const bgPrimary = Color(0xFF1a1b26);
  static const bgSecondary = Color(0xFF24283b);
  static const bgTertiary = Color(0xFF292e42);
  static const textPrimary = Color(0xFFc0caf5);
  static const textSecondary = Color(0xFFa9b1d6);
  static const textMuted = Color(0xFF565f89);
  static const accent = Color(0xFF7aa2f7);
  static const accentHover = Color(0xFF89b4fa);
  static const success = Color(0xFF9ece6a);
  static const warning = Color(0xFFe0af68);
  static const danger = Color(0xFFf7768e);
  static const border = Color(0xFF3b4261);

  // Terminal colors
  static const termBlack = Color(0xFF15161e);
  static const termRed = Color(0xFFf7768e);
  static const termGreen = Color(0xFF9ece6a);
  static const termYellow = Color(0xFFe0af68);
  static const termBlue = Color(0xFF7aa2f7);
  static const termMagenta = Color(0xFFbb9af7);
  static const termCyan = Color(0xFF7dcfff);
  static const termWhite = Color(0xFFa9b1d6);
  static const termBrightBlack = Color(0xFF414868);
  static const termBrightWhite = Color(0xFFc0caf5);

  static ThemeData get theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bgPrimary,
        primaryColor: accent,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accentHover,
          surface: bgSecondary,
          error: danger,
          onPrimary: bgPrimary,
          onSecondary: bgPrimary,
          onSurface: textPrimary,
          onError: textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: bgSecondary,
          foregroundColor: textPrimary,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: bgPrimary,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: accent),
          ),
          labelStyle: const TextStyle(color: textMuted),
          hintStyle: const TextStyle(color: textMuted),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: bgPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: accent),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: bgSecondary,
          contentTextStyle: TextStyle(color: textPrimary),
        ),
        cardTheme: CardTheme(
          color: bgSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: border),
          ),
        ),
      );
}
