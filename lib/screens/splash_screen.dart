import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _progressAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _progressAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
    _initApp();
  }

  Future<void> _initApp() async {
    final auth = context.read<AuthService>();
    final themeSvc = context.read<ThemeService>();
    await Future.wait([auth.init(), themeSvc.init()]);
    await Future.delayed(const Duration(milliseconds: 2800));
    if (!mounted) return;
    if (auth.isLoggedIn && auth.serverUrl != null) {
      Navigator.pushReplacementNamed(context, '/home');
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    return Scaffold(
      backgroundColor: t.bgPrimary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/logo.png', width: 220),
            const SizedBox(height: 20),
            Text(
              'Connecting...',
              style: TextStyle(
                color: t.textMuted,
                fontSize: 14,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 120,
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: AnimatedBuilder(
                  animation: _progressAnim,
                  builder: (context, _) {
                    return LinearProgressIndicator(
                      value: _progressAnim.value,
                      backgroundColor: t.bgTertiary,
                      valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                      minHeight: 3,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
