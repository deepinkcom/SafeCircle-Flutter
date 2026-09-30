import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../widgets/safe_circle_mark.dart';

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({
    super.key,
    required this.onBack,
    required this.onCreateAccount,
    required this.onLogIn,
  });

  final VoidCallback onBack;
  final ValueChanged<String> onCreateAccount;
  final VoidCallback onLogIn;

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _fullName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _agreed = false;
  bool _showPw = false;
  bool _showConfirmPw = false;

  @override
  void dispose() {
    _fullName.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, color: AppColors.tealPrimary),
              ),
              Center(
                child: Column(
                  children: [
                    const SafeCircleMark(size: 72),
                    const SizedBox(height: 8),
                    Text('SafeCircle', style: textTheme.headlineMedium),
                    const SizedBox(height: 12),
                    Text('Create Account', style: textTheme.headlineMedium?.copyWith(fontSize: 26)),
                    Text('Join your community safety circle', style: textTheme.bodyMedium),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _fullName,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  hintText: 'Enter your full name',
                  prefixIcon: Icon(Icons.person, color: AppColors.tealPrimary),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'Enter your email address',
                  prefixIcon: Icon(Icons.email, color: AppColors.tealPrimary),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  hintText: 'Enter your mobile number',
                  prefixIcon: Icon(Icons.phone, color: AppColors.tealPrimary),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                obscureText: !_showPw,
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Create a strong password',
                  prefixIcon: const Icon(Icons.lock, color: AppColors.tealPrimary),
                  suffixIcon: IconButton(
                    icon: Icon(_showPw ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.textMuted),
                    onPressed: () => setState(() => _showPw = !_showPw),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirmPassword,
                obscureText: !_showConfirmPw,
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  hintText: 'Re-enter your password',
                  prefixIcon: const Icon(Icons.lock, color: AppColors.tealPrimary),
                  suffixIcon: IconButton(
                    icon: Icon(_showConfirmPw ? Icons.visibility_off : Icons.visibility,
                        color: AppColors.textMuted),
                    onPressed: () => setState(() => _showConfirmPw = !_showConfirmPw),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () => setState(() => _agreed = !_agreed),
                child: Row(
                  children: [
                    Checkbox(
                      value: _agreed,
                      activeColor: AppColors.tealPrimary,
                      onChanged: (v) => setState(() => _agreed = v ?? false),
                    ),
                    const Expanded(
                      child: Wrap(
                        children: [
                          Text('I agree to the ', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                          Text('Privacy Policy',
                              style: TextStyle(
                                  color: AppColors.tealPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          Text(' and ', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                          Text('Terms of Service',
                              style: TextStyle(
                                  color: AppColors.tealPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _agreed
                      ? () => widget.onCreateAccount(
                          _fullName.text.trim().isEmpty ? 'New Member' : _fullName.text.trim())
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.navyDark,
                    disabledBackgroundColor: AppColors.navyDark.withValues(alpha: 0.4),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                  icon: const Icon(Icons.person_add_alt, size: 18),
                  label: const Text('Create Account',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: const [
                  Expanded(child: Divider(color: AppColors.divider)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('OR', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                  ),
                  Expanded(child: Divider(color: AppColors.divider)),
                ],
              ),
              const SizedBox(height: 14),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Already have an account? ',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
                    GestureDetector(
                      onTap: widget.onLogIn,
                      child: const Text('Log In',
                          style: TextStyle(
                              color: AppColors.tealPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Card(
                color: AppColors.tealBg,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.lock, color: AppColors.tealPrimary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Emergency alerts only use your location when needed to keep you and your community safe.',
                          style: textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
