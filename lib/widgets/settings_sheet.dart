import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../theme.dart';

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
  Color _pwMsgColor = TokyoNight.danger;
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
    if (_newPwCtrl.text != _confirmPwCtrl.text) {
      setState(() {
        _pwMsg = 'Passwords do not match';
        _pwMsgColor = TokyoNight.danger;
      });
      return;
    }
    try {
      final auth = context.read<AuthService>();
      final result = await auth.changePassword(_oldPwCtrl.text, _newPwCtrl.text);
      setState(() {
        if (result['success'] == true) {
          _pwMsg = 'Password changed successfully';
          _pwMsgColor = TokyoNight.success;
          _oldPwCtrl.clear();
          _newPwCtrl.clear();
          _confirmPwCtrl.clear();
        } else {
          _pwMsg = result['error'] as String? ?? 'Failed';
          _pwMsgColor = TokyoNight.danger;
        }
      });
    } catch (e) {
      setState(() {
        _pwMsg = 'Connection error';
        _pwMsgColor = TokyoNight.danger;
      });
    }
  }

  Future<void> _setupTFA() async {
    try {
      final auth = context.read<AuthService>();
      final data = await auth.setup2FA();
      if (data['secret'] != null) {
        setState(() {
          _showSetup = true;
          _tfaSecret = data['secret'] as String?;
          _tfaCodeCtrl.clear();
          _tfaMsg = null;
        });
      }
    } catch (_) {}
  }

  Future<void> _verifyTFA() async {
    if (_tfaCodeCtrl.text.length != 6) {
      setState(() => _tfaMsg = 'Enter 6-digit code');
      return;
    }
    try {
      final auth = context.read<AuthService>();
      final result = await auth.enable2FA(_tfaCodeCtrl.text.trim());
      if (result['success'] == true) {
        setState(() {
          _showSetup = false;
          _tfaMsg = null;
        });
        _loadTFAStatus();
      } else {
        setState(() {
          _tfaMsg = result['error'] as String? ?? 'Failed';
          _tfaCodeCtrl.clear();
        });
      }
    } catch (_) {
      setState(() => _tfaMsg = 'Connection error');
    }
  }

  Future<void> _disableTFA() async {
    if (_disablePwCtrl.text.isEmpty) {
      setState(() => _tfaMsg = 'Enter your password');
      return;
    }
    try {
      final auth = context.read<AuthService>();
      final result = await auth.disable2FA(_disablePwCtrl.text);
      if (result['success'] == true) {
        setState(() {
          _showDisable = false;
          _tfaMsg = null;
        });
        _loadTFAStatus();
      } else {
        setState(() => _tfaMsg = result['error'] as String? ?? 'Failed');
      }
    } catch (_) {
      setState(() => _tfaMsg = 'Connection error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: TokyoNight.bgSecondary,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(20),
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TokyoNight.textMuted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'SETTINGS',
                style: TextStyle(
                  color: TokyoNight.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),

              // Change Password
              _sectionTitle('Change Password'),
              const SizedBox(height: 10),
              _input(_oldPwCtrl, 'Current Password', obscure: true),
              const SizedBox(height: 10),
              _input(_newPwCtrl, 'New Password', obscure: true),
              const SizedBox(height: 10),
              _input(_confirmPwCtrl, 'Confirm New Password', obscure: true),
              const SizedBox(height: 12),
              _actionButton('Change Password', _changePassword),
              if (_pwMsg != null) ...[
                const SizedBox(height: 8),
                Text(
                  _pwMsg!,
                  style: TextStyle(color: _pwMsgColor, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              const Divider(color: TokyoNight.border),
              const SizedBox(height: 16),

              // 2FA
              _sectionTitle('Two-Factor Authentication'),
              const SizedBox(height: 10),
              if (_tfaEnabled == null)
                const Text('Loading...',
                    style: TextStyle(color: TokyoNight.textMuted, fontSize: 13))
              else if (_showSetup)
                _build2FASetup()
              else if (_showDisable)
                _build2FADisable()
              else ...[
                Text(
                  _tfaEnabled! ? '2FA is enabled' : '2FA is not enabled',
                  style: TextStyle(
                    color:
                        _tfaEnabled! ? TokyoNight.success : TokyoNight.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 12),
                _actionButton(
                  _tfaEnabled! ? 'Disable 2FA' : 'Enable 2FA',
                  () {
                    if (_tfaEnabled!) {
                      setState(() {
                        _showDisable = true;
                        _disablePwCtrl.clear();
                        _tfaMsg = null;
                      });
                    } else {
                      _setupTFA();
                    }
                  },
                  color: _tfaEnabled! ? TokyoNight.danger : TokyoNight.accent,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _build2FASetup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Enter the secret key in your authenticator app:',
          style: TextStyle(color: TokyoNight.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: TokyoNight.bgPrimary,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: TokyoNight.border),
          ),
          child: SelectableText(
            _tfaSecret ?? '',
            style: const TextStyle(
              color: TokyoNight.textPrimary,
              fontFamily: 'monospace',
              fontSize: 14,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _input(_tfaCodeCtrl, 'Enter 6-digit code',
            keyboardType: TextInputType.number,
            maxLength: 6,
            formatters: [FilteringTextInputFormatter.digitsOnly]),
        const SizedBox(height: 12),
        _actionButton('Verify & Enable', _verifyTFA),
        const SizedBox(height: 8),
        _actionButton('Cancel', () {
          setState(() {
            _showSetup = false;
            _tfaMsg = null;
          });
        }, color: Colors.transparent, textColor: TokyoNight.textMuted),
        if (_tfaMsg != null) ...[
          const SizedBox(height: 8),
          Text(_tfaMsg!,
              style: const TextStyle(color: TokyoNight.danger, fontSize: 13),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Widget _build2FADisable() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _input(_disablePwCtrl, 'Enter password to disable 2FA', obscure: true),
        const SizedBox(height: 12),
        _actionButton('Disable 2FA', _disableTFA, color: TokyoNight.danger),
        const SizedBox(height: 8),
        _actionButton('Cancel', () {
          setState(() {
            _showDisable = false;
            _tfaMsg = null;
          });
        }, color: Colors.transparent, textColor: TokyoNight.textMuted),
        if (_tfaMsg != null) ...[
          const SizedBox(height: 8),
          Text(_tfaMsg!,
              style: const TextStyle(color: TokyoNight.danger, fontSize: 13),
              textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: TokyoNight.textMuted,
        fontSize: 11,
        letterSpacing: 0.5,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    TextInputType? keyboardType,
    int? maxLength,
    List<TextInputFormatter>? formatters,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      maxLength: maxLength,
      inputFormatters: formatters,
      style: const TextStyle(color: TokyoNight.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _actionButton(String label, VoidCallback onPressed,
      {Color? color, Color? textColor}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? TokyoNight.accent,
          foregroundColor: textColor ?? TokyoNight.bgPrimary,
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: color == Colors.transparent
              ? const BorderSide(color: TokyoNight.border)
              : null,
        ),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}
