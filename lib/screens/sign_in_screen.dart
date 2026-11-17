import 'package:flutter/material.dart';

import '../state/quiz_controller.dart';
import '../widgets/common.dart';

/// Email/password sign-in. The password lives only in this form's text
/// field: it is never stored, logged or kept after the screen closes.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.controller});

  final QuizController controller;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    FocusScope.of(context).unfocus();
    widget.controller.signIn(_email.text, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('ICA16 Cloud Quiz')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Text('Sign in to play', style: text.headlineSmall),
              const SizedBox(height: 4),
              const Text('General Knowledge, Class A. Scores are saved to '
                  'your own cloud account.'),
              const SizedBox(height: 16),
              if (controller.phase == QuizPhase.authError) ...<Widget>[
                StatusBanner(
                  icon: Icons.error_outline,
                  color: kWrongColor,
                  title: 'Sign-in failed',
                  detail: controller.message,
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value == null || value.trim().isEmpty)
                        ? 'Enter your email.'
                        : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Enter your password.'
                    : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: controller.signingIn ? null : _submit,
                child: Text(controller.signingIn ? 'Signing in' : 'Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
