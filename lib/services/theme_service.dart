import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

class AppThemeData {
  final String name;
  final Color bgPrimary;
  final Color bgSecondary;
  final Color bgTertiary;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentHover;
  final Color success;
  final Color warning;
  final Color danger;
  final Color border;
  // Terminal colors
  final Color termBlack;
  final Color termRed;
  final Color termGreen;
  final Color termYellow;
  final Color termBlue;
  final Color termMagenta;
  final Color termCyan;
  final Color termWhite;
  final Color termBrightBlack;
  final Color termBrightWhite;
  final Color termSelection;

  const AppThemeData({
    required this.name,
    required this.bgPrimary,
    required this.bgSecondary,
    required this.bgTertiary,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentHover,
    required this.success,
    required this.warning,
    required this.danger,
    required this.border,
    required this.termBlack,
    required this.termRed,
    required this.termGreen,
    required this.termYellow,
    required this.termBlue,
    required this.termMagenta,
    required this.termCyan,
    required this.termWhite,
    required this.termBrightBlack,
    required this.termBrightWhite,
    required this.termSelection,
  });

  ThemeData toFlutterTheme() => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bgPrimary,
        primaryColor: accent,
        colorScheme: ColorScheme.dark(
          primary: accent,
          secondary: accentHover,
          surface: bgSecondary,
          error: danger,
          onPrimary: bgPrimary,
          onSecondary: bgPrimary,
          onSurface: textPrimary,
          onError: textPrimary,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: bgSecondary,
          foregroundColor: textPrimary,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: bgPrimary,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: accent),
          ),
          labelStyle: TextStyle(color: textMuted),
          hintStyle: TextStyle(color: textMuted),
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
        cardTheme: CardTheme(
          color: bgSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: border),
          ),
        ),
      );

  TerminalTheme toTerminalTheme() => TerminalTheme(
        cursor: textPrimary,
        selection: termSelection,
        foreground: textSecondary,
        background: bgPrimary,
        black: termBlack,
        red: termRed,
        green: termGreen,
        yellow: termYellow,
        blue: termBlue,
        magenta: termMagenta,
        cyan: termCyan,
        white: termWhite,
        brightBlack: termBrightBlack,
        brightRed: termRed,
        brightGreen: termGreen,
        brightYellow: termYellow,
        brightBlue: termBlue,
        brightMagenta: termMagenta,
        brightCyan: termCyan,
        brightWhite: termBrightWhite,
        searchHitBackground: accent,
        searchHitBackgroundCurrent: warning,
        searchHitForeground: bgPrimary,
      );
}

class ThemeService extends ChangeNotifier {
  static const _key = 'selected_theme';
  static const _fontSizeKey = 'terminal_font_size';
  String _currentThemeName = 'Tokyo Night';
  double _terminalFontSize = 13.0;

  String get currentThemeName => _currentThemeName;
  AppThemeData get current => themes[_currentThemeName] ?? themes['Tokyo Night']!;
  double get terminalFontSize => _terminalFontSize;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _currentThemeName = prefs.getString(_key) ?? 'Tokyo Night';
    _terminalFontSize = prefs.getDouble(_fontSizeKey) ?? 13.0;
    notifyListeners();
  }

  Future<void> setTheme(String name) async {
    if (!themes.containsKey(name)) return;
    _currentThemeName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, name);
    notifyListeners();
  }

  Future<void> setTerminalFontSize(double size) async {
    _terminalFontSize = size.clamp(8.0, 24.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontSizeKey, _terminalFontSize);
    notifyListeners();
  }

  static final Map<String, AppThemeData> themes = {
    'Tokyo Night': const AppThemeData(
      name: 'Tokyo Night',
      bgPrimary: Color(0xFF1a1b26),
      bgSecondary: Color(0xFF24283b),
      bgTertiary: Color(0xFF292e42),
      textPrimary: Color(0xFFc0caf5),
      textSecondary: Color(0xFFa9b1d6),
      textMuted: Color(0xFF565f89),
      accent: Color(0xFF7aa2f7),
      accentHover: Color(0xFF89b4fa),
      success: Color(0xFF9ece6a),
      warning: Color(0xFFe0af68),
      danger: Color(0xFFf7768e),
      border: Color(0xFF3b4261),
      termBlack: Color(0xFF15161e),
      termRed: Color(0xFFf7768e),
      termGreen: Color(0xFF9ece6a),
      termYellow: Color(0xFFe0af68),
      termBlue: Color(0xFF7aa2f7),
      termMagenta: Color(0xFFbb9af7),
      termCyan: Color(0xFF7dcfff),
      termWhite: Color(0xFFa9b1d6),
      termBrightBlack: Color(0xFF414868),
      termBrightWhite: Color(0xFFc0caf5),
      termSelection: Color(0xFF33467c),
    ),
    'Dracula': const AppThemeData(
      name: 'Dracula',
      bgPrimary: Color(0xFF282a36),
      bgSecondary: Color(0xFF343746),
      bgTertiary: Color(0xFF3e4155),
      textPrimary: Color(0xFFf8f8f2),
      textSecondary: Color(0xFFe0def4),
      textMuted: Color(0xFF6272a4),
      accent: Color(0xFFbd93f9),
      accentHover: Color(0xFFcaa9fa),
      success: Color(0xFF50fa7b),
      warning: Color(0xFFf1fa8c),
      danger: Color(0xFFff5555),
      border: Color(0xFF44475a),
      termBlack: Color(0xFF21222c),
      termRed: Color(0xFFff5555),
      termGreen: Color(0xFF50fa7b),
      termYellow: Color(0xFFf1fa8c),
      termBlue: Color(0xFFbd93f9),
      termMagenta: Color(0xFFff79c6),
      termCyan: Color(0xFF8be9fd),
      termWhite: Color(0xFFf8f8f2),
      termBrightBlack: Color(0xFF6272a4),
      termBrightWhite: Color(0xFFffffff),
      termSelection: Color(0xFF44475a),
    ),
    'Monokai': const AppThemeData(
      name: 'Monokai',
      bgPrimary: Color(0xFF272822),
      bgSecondary: Color(0xFF2d2e27),
      bgTertiary: Color(0xFF3e3d32),
      textPrimary: Color(0xFFf8f8f2),
      textSecondary: Color(0xFFe6db74),
      textMuted: Color(0xFF75715e),
      accent: Color(0xFFa6e22e),
      accentHover: Color(0xFFb6f23e),
      success: Color(0xFFa6e22e),
      warning: Color(0xFFe6db74),
      danger: Color(0xFFf92672),
      border: Color(0xFF49483e),
      termBlack: Color(0xFF272822),
      termRed: Color(0xFFf92672),
      termGreen: Color(0xFFa6e22e),
      termYellow: Color(0xFFf4bf75),
      termBlue: Color(0xFF66d9ef),
      termMagenta: Color(0xFFae81ff),
      termCyan: Color(0xFFa1efe4),
      termWhite: Color(0xFFf8f8f2),
      termBrightBlack: Color(0xFF75715e),
      termBrightWhite: Color(0xFFf9f8f5),
      termSelection: Color(0xFF49483e),
    ),
    'Nord': const AppThemeData(
      name: 'Nord',
      bgPrimary: Color(0xFF2e3440),
      bgSecondary: Color(0xFF3b4252),
      bgTertiary: Color(0xFF434c5e),
      textPrimary: Color(0xFFeceff4),
      textSecondary: Color(0xFFd8dee9),
      textMuted: Color(0xFF616e88),
      accent: Color(0xFF88c0d0),
      accentHover: Color(0xFF8fbcbb),
      success: Color(0xFFa3be8c),
      warning: Color(0xFFebcb8b),
      danger: Color(0xFFbf616a),
      border: Color(0xFF4c566a),
      termBlack: Color(0xFF3b4252),
      termRed: Color(0xFFbf616a),
      termGreen: Color(0xFFa3be8c),
      termYellow: Color(0xFFebcb8b),
      termBlue: Color(0xFF81a1c1),
      termMagenta: Color(0xFFb48ead),
      termCyan: Color(0xFF88c0d0),
      termWhite: Color(0xFFe5e9f0),
      termBrightBlack: Color(0xFF4c566a),
      termBrightWhite: Color(0xFFeceff4),
      termSelection: Color(0xFF434c5e),
    ),
    'Solarized Dark': const AppThemeData(
      name: 'Solarized Dark',
      bgPrimary: Color(0xFF002b36),
      bgSecondary: Color(0xFF073642),
      bgTertiary: Color(0xFF0a4050),
      textPrimary: Color(0xFF839496),
      textSecondary: Color(0xFF93a1a1),
      textMuted: Color(0xFF586e75),
      accent: Color(0xFF268bd2),
      accentHover: Color(0xFF2aa1e3),
      success: Color(0xFF859900),
      warning: Color(0xFFb58900),
      danger: Color(0xFFdc322f),
      border: Color(0xFF2a5a68),
      termBlack: Color(0xFF073642),
      termRed: Color(0xFFdc322f),
      termGreen: Color(0xFF859900),
      termYellow: Color(0xFFb58900),
      termBlue: Color(0xFF268bd2),
      termMagenta: Color(0xFFd33682),
      termCyan: Color(0xFF2aa198),
      termWhite: Color(0xFFeee8d5),
      termBrightBlack: Color(0xFF586e75),
      termBrightWhite: Color(0xFFfdf6e3),
      termSelection: Color(0xFF073642),
    ),
  };
}
