import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';
import '../services/terminal_history_service.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  final _oldPwCtrl = TextEditingController();
  final _newPwCtrl = TextEditingController();
  final _confirmPwCtrl = TextEditingController();
  final _tfaCodeCtrl = TextEditingController();
  final _disablePwCtrl = TextEditingController();

  String? _pwMsg;
  Color? _pwMsgColor;
  bool? _tfaEnabled;
  bool _showSetup = false;
  bool _showDisable = false;
  String? _tfaSecret;
  String? _tfaMsg;

  @override
  void initState() {
    super.initState();
    _loadTFAStatus();
  }

  @override
  void dispose() {
    _oldPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confirmPwCtrl.dispose();
    _tfaCodeCtrl.dispose();
    _disablePwCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTFAStatus() async {
    try {
      final auth = context.read<AuthService>();
      final data = await auth.get2FAStatus();
      if (mounted) setState(() => _tfaEnabled = data['enabled'] == true);
    } catch (_) {}
  }

  Future<void> _changePassword() async {
    final t = context.read<ThemeService>().current;
    if (_newPwCtrl.text != _confirmPwCtrl.text) {
      setState(() { _pwMsg = 'Passwords do not match'; _pwMsgColor = t.danger; });
      return;
    }
    try {
      final auth = context.read<AuthService>();
      final result = await auth.changePassword(_oldPwCtrl.text, _newPwCtrl.text);
      if (!mounted) return;
      setState(() {
        if (result['success'] == true) {
          _pwMsg = 'Password changed successfully'; _pwMsgColor = t.success;
          _oldPwCtrl.clear(); _newPwCtrl.clear(); _confirmPwCtrl.clear();
        } else {
          _pwMsg = result['error'] as String? ?? 'Failed'; _pwMsgColor = t.danger;
        }
      });
    } catch (e) {
      if (mounted) setState(() { _pwMsg = 'Connection error'; _pwMsgColor = t.danger; });
    }
  }

  Future<void> _setupTFA() async {
    try {
      final auth = context.read<AuthService>();
      final data = await auth.setup2FA();
      if (!mounted) return;
      if (data['secret'] != null) {
        setState(() {
          _showSetup = true; _tfaSecret = data['secret'] as String?;
          _tfaCodeCtrl.clear(); _tfaMsg = null;
        });
      }
    } catch (_) {}
  }

  Future<void> _verifyTFA() async {
    if (_tfaCodeCtrl.text.length != 6) { setState(() => _tfaMsg = 'Enter 6-digit code'); return; }
    try {
      final auth = context.read<AuthService>();
      final result = await auth.enable2FA(_tfaCodeCtrl.text.trim());
      if (!mounted) return;
      if (result['success'] == true) {
        setState(() { _showSetup = false; _tfaMsg = null; });
        _loadTFAStatus();
      } else {
        setState(() { _tfaMsg = result['error'] as String? ?? 'Failed'; _tfaCodeCtrl.clear(); });
      }
    } catch (_) { if (mounted) setState(() => _tfaMsg = 'Connection error'); }
  }

  Future<void> _disableTFA() async {
    if (_disablePwCtrl.text.isEmpty) { setState(() => _tfaMsg = 'Enter your password'); return; }
    try {
      final auth = context.read<AuthService>();
      final result = await auth.disable2FA(_disablePwCtrl.text);
      if (!mounted) return;
      if (result['success'] == true) {
        setState(() { _showDisable = false; _tfaMsg = null; });
        _loadTFAStatus();
      } else { setState(() => _tfaMsg = result['error'] as String? ?? 'Failed'); }
    } catch (_) { if (mounted) setState(() => _tfaMsg = 'Connection error'); }
  }

  Future<void> _clearHistory() async {
    await TerminalHistoryService.clearAll();
    if (mounted) {
      final t = context.read<ThemeService>().current;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Terminal history cleared'), backgroundColor: t.success),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.watch<ThemeService>().current;
    return DraggableScrollableSheet(
      initialChildSize: 0.75, maxChildSize: 0.95, minChildSize: 0.4,
      builder: (ctx, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: t.bgSecondary,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              Center(child: Container(width: 40, height: 4,
                decoration: BoxDecoration(color: t.textMuted, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Text('SETTINGS', style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 24),

              // Theme Selection
              _sectionTitle(t, 'Theme'),
              const SizedBox(height: 10),
              ...ThemeService.themes.keys.map((name) {
                final isActive = name == context.read<ThemeService>().currentThemeName;
                final preview = ThemeService.themes[name]!;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => context.read<ThemeService>().setTheme(name),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: isActive ? t.accent.withOpacity(0.15) : t.bgPrimary,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: isActive ? t.accent : t.border),
                      ),
                      child: Row(
                        children: [
                          // Color preview dots
                          ...[preview.bgPrimary, preview.accent, preview.success, preview.danger].map((c) =>
                            Container(width: 14, height: 14, margin: const EdgeInsets.only(right: 6),
                              decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: t.border, width: 0.5)))),
                          const SizedBox(width: 6),
                          Expanded(child: Text(name, style: TextStyle(
                            color: isActive ? t.accent : t.textPrimary, fontSize: 14,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal))),
                          if (isActive) Icon(Icons.check, size: 18, color: t.accent),
                        ],
                      ),
                    ),
                  ),
                );
              }),

              const SizedBox(height: 20),
              Divider(color: t.border),
              const SizedBox(height: 16),

              // Change Password
              _sectionTitle(t, 'Change Password'),
              const SizedBox(height: 10),
              _input(t, _oldPwCtrl, 'Current Password', obscure: true),
              const SizedBox(height: 10),
              _input(t, _newPwCtrl, 'New Password', obscure: true),
              const SizedBox(height: 10),
              _input(t, _confirmPwCtrl, 'Confirm New Password', obscure: true),
              const SizedBox(height: 12),
              _actionButton(t, 'Change Password', _changePassword),
              if (_pwMsg != null) ...[
                const SizedBox(height: 8),
                Text(_pwMsg!, style: TextStyle(color: _pwMsgColor ?? t.danger, fontSize: 13), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 20),
              Divider(color: t.border),
              const SizedBox(height: 16),

              // 2FA
              _sectionTitle(t, 'Two-Factor Authentication'),
              const SizedBox(height: 10),
              if (_tfaEnabled == null)
                Text('Loading...', style: TextStyle(color: t.textMuted, fontSize: 13))
              else if (_showSetup)
                _build2FASetup(t)
              else if (_showDisable)
                _build2FADisable(t)
              else ...[
                Text(_tfaEnabled! ? '2FA is enabled' : '2FA is not enabled',
                  style: TextStyle(color: _tfaEnabled! ? t.success : t.textMuted, fontSize: 13)),
                const SizedBox(height: 12),
                _actionButton(t, _tfaEnabled! ? 'Disable 2FA' : 'Enable 2FA', () {
                  if (_tfaEnabled!) {
                    setState(() { _showDisable = true; _disablePwCtrl.clear(); _tfaMsg = null; });
                  } else { _setupTFA(); }
                }, color: _tfaEnabled! ? t.danger : t.accent),
              ],

              const SizedBox(height: 20),
              Divider(color: t.border),
              const SizedBox(height: 16),

              // Terminal Settings
              _sectionTitle(t, 'Terminal'),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('Font Size: ${context.watch<ThemeService>().terminalFontSize.toInt()}',
                    style: TextStyle(color: t.textMuted, fontSize: 13)),
                  Expanded(
                    child: Slider(
                      value: context.watch<ThemeService>().terminalFontSize,
                      min: 8, max: 24,
                      divisions: 16,
                      activeColor: t.accent,
                      onChanged: (v) => context.read<ThemeService>().setTerminalFontSize(v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('Terminal output is saved locally for session restoration.',
                style: TextStyle(color: t.textMuted, fontSize: 12)),
              const SizedBox(height: 12),
              _actionButton(t, 'Clear Terminal History', _clearHistory, color: t.danger),
            ],
          ),
        );
      },
    );
  }

  Widget _build2FASetup(AppThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Enter the secret key in your authenticator app:',
          style: TextStyle(color: t.textMuted, fontSize: 12)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.bgPrimary, borderRadius: BorderRadius.circular(8), border: Border.all(color: t.border)),
          child: SelectableText(_tfaSecret ?? '',
            style: TextStyle(color: t.textPrimary, fontFamily: 'monospace', fontSize: 14, letterSpacing: 2)),
        ),
        const SizedBox(height: 16),
        _input(t, _tfaCodeCtrl, 'Enter 6-digit code',
            keyboardType: TextInputType.number, maxLength: 6,
            formatters: [FilteringTextInputFormatter.digitsOnly]),
        const SizedBox(height: 12),
        _actionButton(t, 'Verify & Enable', _verifyTFA),
        const SizedBox(height: 8),
        _actionButton(t, 'Cancel', () { setState(() { _showSetup = false; _tfaMsg = null; }); },
          color: Colors.transparent, textColor: t.textMuted),
        if (_tfaMsg != null) ...[
          const SizedBox(height: 8),
          Text(_tfaMsg!, style: TextStyle(color: t.danger, fontSize: 13), textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Widget _build2FADisable(AppThemeData t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _input(t, _disablePwCtrl, 'Enter password to disable 2FA', obscure: true),
        const SizedBox(height: 12),
        _actionButton(t, 'Disable 2FA', _disableTFA, color: t.danger),
        const SizedBox(height: 8),
        _actionButton(t, 'Cancel', () { setState(() { _showDisable = false; _tfaMsg = null; }); },
          color: Colors.transparent, textColor: t.textMuted),
        if (_tfaMsg != null) ...[
          const SizedBox(height: 8),
          Text(_tfaMsg!, style: TextStyle(color: t.danger, fontSize: 13), textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Widget _sectionTitle(AppThemeData t, String text) {
    return Text(text.toUpperCase(),
      style: TextStyle(color: t.textMuted, fontSize: 11, letterSpacing: 0.5, fontWeight: FontWeight.w600));
  }

  Widget _input(AppThemeData t, TextEditingController controller, String label, {
    bool obscure = false, TextInputType? keyboardType, int? maxLength,
    List<TextInputFormatter>? formatters,
  }) {
    return TextField(
      controller: controller, obscureText: obscure, keyboardType: keyboardType,
      maxLength: maxLength, inputFormatters: formatters,
      style: TextStyle(color: t.textPrimary, fontSize: 14),
      decoration: InputDecoration(labelText: label, counterText: '',
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
    );
  }

  Widget _actionButton(AppThemeData t, String label, VoidCallback onPressed, {Color? color, Color? textColor}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? t.accent,
          foregroundColor: textColor ?? t.bgPrimary,
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: color == Colors.transparent ? BorderSide(color: t.border) : null,
        ),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}
