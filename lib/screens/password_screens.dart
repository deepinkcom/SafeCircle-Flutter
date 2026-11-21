import 'package:flutter/material.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen(
      {super.key, required this.onSend, this.initialEmail = ''});
  final Future<String?> Function(String email) onSend;
  final String initialEmail;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail);
  bool _busy = false;
  bool _sent = false;
  String? _error;

  Future<void> _send() async {
    if (_busy || _sent || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onSend(_email.text.trim());
    } catch (_) {
      error = 'The reset email request could not complete. Please try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _sent = error == null;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Reset Password')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                      'Enter your account email to request a password reset link.'),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _email,
                    enabled: !_busy && !_sent,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                    validator: (value) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                            .hasMatch((value ?? '').trim())
                        ? null
                        : 'Enter a valid email address.',
                    onFieldSubmitted: (_) => _send(),
                  ),
                  const SizedBox(height: 20),
                  if (_sent) ...[
                    const Text(
                        "If an email/password account exists for that address, you’ll receive a reset link. Check your inbox and spam folder. Open the link to choose a new password.",
                        semanticsLabel:
                            'Password reset requested. Check your inbox and spam folder.'),
                    const SizedBox(height: 16),
                    FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Back to Log In')),
                  ] else ...[
                    if (_error != null) ...[
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 12),
                    ],
                    FilledButton(
                        onPressed: _busy ? null : _send,
                        child: Text(
                            _busy ? 'Requesting reset…' : 'Send reset email')),
                  ],
                  const SizedBox(height: 24),
                  const Text(
                      'If you use Google sign-in, manage your Google password in your Google Account.'),
                ],
              )),
        ),
      );
}

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen(
      {super.key, required this.passwordEnabled, required this.onChange});
  final bool passwordEnabled;
  final Future<String?> Function(String currentPassword, String newPassword)
      onChange;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _saved = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy ||
        _saved ||
        !widget.passwordEnabled ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onChange(_current.text, _next.text);
    } catch (_) {
      error =
          'The password update could not be confirmed. Retry or use Forgot Password.';
    }
    if (!mounted) return;
    if (error == null) {
      _current.clear();
      _next.clear();
      _confirm.clear();
    }
    setState(() {
      _busy = false;
      _error = error;
      _saved = error == null;
    });
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Change Password')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: !widget.passwordEnabled
                ? const Text(
                    'This account uses Google sign-in. Manage your Google password in your Google Account.',
                  )
                : _saved
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Your password has been changed.'),
                          const SizedBox(height: 20),
                          FilledButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Back to Profile')),
                        ],
                      )
                    : AutofillGroup(
                        child: Form(
                            key: _form,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                    'Confirm your current password, then choose a new one.'),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: _current,
                                  enabled: !_busy,
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  autofillHints: const [AutofillHints.password],
                                  decoration: const InputDecoration(
                                      labelText: 'Current password'),
                                  validator: (value) => (value ?? '').isEmpty
                                      ? 'Enter your current password.'
                                      : null,
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _next,
                                  enabled: !_busy,
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  autofillHints: const [
                                    AutofillHints.newPassword
                                  ],
                                  decoration: const InputDecoration(
                                      labelText: 'New password'),
                                  validator: (value) => (value ?? '').length < 6
                                      ? 'Use at least 6 characters for your new password.'
                                      : value == _current.text
                                          ? 'Choose a different new password.'
                                          : null,
                                ),
                                const SizedBox(height: 16),
                                TextFormField(
                                  controller: _confirm,
                                  enabled: !_busy,
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  autofillHints: const [
                                    AutofillHints.newPassword
                                  ],
                                  decoration: const InputDecoration(
                                      labelText: 'Confirm new password'),
                                  validator: (value) => value != _next.text
                                      ? 'The new passwords do not match.'
                                      : null,
                                  onFieldSubmitted: (_) => _submit(),
                                ),
                                const SizedBox(height: 20),
                                if (_error != null) ...[
                                  Text(_error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                  const SizedBox(height: 12),
                                ],
                                FilledButton(
                                    onPressed: _busy ? null : _submit,
                                    child: Text(_busy
                                        ? 'Changing password…'
                                        : 'Save new password')),
                              ],
                            ))),
          ),
        ),
      );
}
