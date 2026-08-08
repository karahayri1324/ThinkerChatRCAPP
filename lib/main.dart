import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/auth_service.dart';
import 'services/ws_service.dart';
import 'services/theme_service.dart';
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

/// Global navigator so session-expiry (which can be detected from any HTTP
/// call or the WS layer) can return the app to the login screen no matter
/// which screen is on top.
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF1a1b26),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final auth = AuthService();
  final ws = WsService();
  final themeSvc = ThemeService();

  // When the server rejects our token, drop the socket and land on the login
  // screen (with the session notice) from wherever the user happens to be.
  auth.onSessionExpired = () {
    ws.disconnect();
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.pushNamedAndRemoveUntil('/login', (route) => false);
    }
  };

  runApp(RCApp(auth: auth, ws: ws, themeSvc: themeSvc));
}

class RCApp extends StatelessWidget {
  final AuthService auth;
  final WsService ws;
  final ThemeService themeSvc;

  const RCApp({
    super.key,
    required this.auth,
    required this.ws,
    required this.themeSvc,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: ws),
        ChangeNotifierProvider.value(value: themeSvc),
      ],
      child: Consumer<ThemeService>(
        builder: (context, themeSvc, _) {
          final t = themeSvc.current;
          SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            systemNavigationBarColor: t.bgPrimary,
            systemNavigationBarIconBrightness: Brightness.light,
          ));
          return MaterialApp(
            title: 'RemoteController',
            debugShowCheckedModeBanner: false,
            navigatorKey: navigatorKey,
            theme: t.toFlutterTheme(),
            initialRoute: '/splash',
            routes: {
              '/splash': (_) => const SplashScreen(),
              '/login': (_) => const LoginScreen(),
              '/home': (_) => const HomeScreen(),
            },
          );
        },
      ),
    );
  }
}
