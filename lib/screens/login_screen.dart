import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/server_history_service.dart';
import '../services/theme_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _tfaCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _notice;
  bool _show2FA = false;
  bool _obscurePassword = true;
  List<ServerProfile> _recentServers = [];

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    if (auth.serverUrl != null) {
      _serverCtrl.text = auth.serverUrl!;
    }
    if (auth.username != null) {
      _userCtrl.text = auth.username!;
    }
    _notice = auth.consumeSessionNotice();
    ServerHistoryService.load().then((profiles) {
      if (mounted) setState(() => _recentServers = profiles);
    });
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _tfaCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    final auth = context.read<AuthService>();
    try {
      await auth.setServerUrl(_serverCtrl.text);
      final result = await auth.login(_userCtrl.text.trim(), _passCtrl.text);
      if (!mounted) return;
      if (!result['success']) {
        setState(() => _error = result['error'] as String?);
      } else if (result['requires_2fa'] == true) {
        setState(() {
          _show2FA = true;
          _error = null;
        });
        _tfaCtrl.clear();
      } else {
        await _onLoggedIn(auth);
      }
    } catch (e) {
      // Surface URL-validation messages clearly; never leak raw exception text.
      if (mounted) {
        setState(
            () => _error = e is FormatException ? e.message : 'Connection error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify2FA() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final auth = context.read<AuthService>();
    try {
      final result = await auth.verify2FA(_tfaCtrl.text.trim());
      if (!mounted) return;
      if (!result['success']) {
        setState(() => _error = result['error'] as String?);
        _tfaCtrl.clear();
      } else {
        await _onLoggedIn(auth);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Connection error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onLoggedIn(AuthService auth) async {
    if (auth.serverUrl != null) {
      await ServerHistoryService.record(auth.serverUrl!, auth.username ?? '');
    }
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/home');
  }

  void _applyProfile(ServerProfile profile) {
    setState(() {
      _serverCtrl.text = profile.url;
      if (profile.username.isNotEmpty) _userCtrl.text = profile.username;
    });
  }

  Future<void> _forgetProfile(ServerProfile profile) async {
    await ServerHistoryService.remove(profile.url);
    final profiles = await ServerHistoryService.load();
    if (mounted) setState(() => _recentServers = profiles);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    return Scaffold(
      backgroundColor: t.bgPrimary,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 380),
            decoration: BoxDecoration(
              color: t.bgSecondary,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(32),
            child: _show2FA ? _build2FAForm(t) : _buildLoginForm(t),
          ),
        ),
      ),
    );
  }

  Widget _buildNoticeBanner(AppThemeData t) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.warning.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.warning.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: t.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_notice!,
                style: TextStyle(color: t.warning, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginForm(AppThemeData t) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('RemoteController',
            style: TextStyle(
                color: t.accent, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('Access your PC from anywhere',
            style: TextStyle(color: t.textMuted, fontSize: 13)),
        const SizedBox(height: 28),
        if (_notice != null) _buildNoticeBanner(t),
        TextField(
          controller: _serverCtrl,
          decoration: InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://your-relay.com',
            suffixIcon: _recentServers.isEmpty
                ? null
                : PopupMenuButton<ServerProfile>(
                    icon: Icon(Icons.history, size: 20, color: t.textMuted),
                    tooltip: 'Recent servers',
                    color: t.bgTertiary,
                    onSelected: _applyProfile,
                    itemBuilder: (_) => [
                      for (final p in _recentServers)
                        PopupMenuItem(
                          value: p,
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(p.url,
                                        style: TextStyle(
                                            color: t.textPrimary, fontSize: 13),
                                        overflow: TextOverflow.ellipsis),
                                    if (p.username.isNotEmpty)
                                      Text(p.username,
                                          style: TextStyle(
                                              color: t.textMuted, fontSize: 11)),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.close,
                                    size: 16, color: t.textMuted),
                                tooltip: 'Forget this server',
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  Navigator.pop(context);
                                  _forgetProfile(p);
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          style: TextStyle(color: t.textPrimary),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          autocorrect: false,
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _userCtrl,
          decoration: const InputDecoration(labelText: 'Username'),
          style: TextStyle(color: t.textPrimary),
          textInputAction: TextInputAction.next,
          autocorrect: false,
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _passCtrl,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_off : Icons.visibility,
                size: 20,
                color: t.textMuted,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          style: TextStyle(color: t.textPrimary),
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _login(),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _login,
            child: _loading
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: t.bgPrimary))
                : const Text('Login'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: TextStyle(color: t.danger, fontSize: 13),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Widget _build2FAForm(AppThemeData t) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.lock_outline, color: t.accent, size: 40),
        const SizedBox(height: 12),
        Text('Two-Factor Authentication',
            style: TextStyle(color: t.textMuted, fontSize: 13)),
        const SizedBox(height: 20),
        TextField(
          controller: _tfaCtrl,
          decoration: const InputDecoration(labelText: 'Enter 6-digit code'),
          style: TextStyle(
              color: t.textPrimary,
              fontSize: 22,
              letterSpacing: 8,
              fontFamily: 'monospace'),
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          // Auto-submit once, and never while a verify is already in flight, so
          // a quick correction can't fire a stale code mid-edit.
          onChanged: (val) {
            if (val.length == 6 && !_loading) _verify2FA();
          },
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _verify2FA,
            child: _loading
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: t.bgPrimary))
                : const Text('Verify'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() {
            _show2FA = false;
            _error = null;
          }),
          child: Text('Back to login',
              style: TextStyle(color: t.textMuted, fontSize: 13)),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: TextStyle(color: t.danger, fontSize: 13),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }
}
