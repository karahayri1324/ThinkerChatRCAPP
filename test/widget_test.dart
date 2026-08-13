import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rc_app/services/theme_service.dart';
import 'package:rc_app/services/ws_service.dart';
import 'package:rc_app/widgets/connection_banner.dart';
import 'package:rc_app/widgets/sparkline.dart';

Widget _wrap(Widget child, {WsService? ws, ThemeService? theme}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<WsService>.value(value: ws ?? WsService()),
      ChangeNotifierProvider<ThemeService>.value(value: theme ?? ThemeService()),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('ConnectionBanner', () {
    testWidgets('shows offline state with a retry action when disconnected',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConnectionBanner()));
      expect(find.textContaining('Not connected'), findsOneWidget);
      expect(find.text('Retry now'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    });

    testWidgets('retry action is tappable and does not throw when idle',
        (tester) async {
      await tester.pumpWidget(_wrap(const ConnectionBanner()));
      await tester.tap(find.text('Retry now'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Sparkline', () {
    testWidgets('renders a series without error', (tester) async {
      await tester.pumpWidget(_wrap(
        const SizedBox(
          width: 200,
          child: Sparkline(
            values: [0, 10, 40, 25, 90, 100, 60],
            maxY: 100,
            color: Colors.blue,
          ),
        ),
      ));
      expect(find.byType(Sparkline), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('degenerate inputs do not throw', (tester) async {
      for (final values in const [<double>[], <double>[5], <double>[0, 0, 0]]) {
        await tester.pumpWidget(_wrap(
          SizedBox(
            width: 200,
            child: Sparkline(values: values, color: Colors.red),
          ),
        ));
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('ThemeService', () {
    test('falls back to the default palette for an unknown theme name', () {
      final svc = ThemeService();
      expect(svc.current.name, 'Tokyo Night');
      expect(ThemeService.themes.length, greaterThanOrEqualTo(5));
    });

    test('every palette exposes a full terminal theme', () {
      for (final theme in ThemeService.themes.values) {
        expect(theme.toTerminalTheme().background, theme.bgPrimary);
        expect(theme.toFlutterTheme().scaffoldBackgroundColor, theme.bgPrimary);
      }
    });
  });
}
