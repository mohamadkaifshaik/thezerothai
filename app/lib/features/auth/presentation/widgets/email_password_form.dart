import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import 'auth_design.dart';
import 'password_reset_dialog.dart';

/// Shared email + password input used by both the sign-in and sign-up
/// screens (one form, not two near-copies).
class EmailPasswordForm extends StatefulWidget {
  const EmailPasswordForm({
    super.key,
    required this.submitLabel,
    required this.onSubmit,
    required this.isSubmitting,
    this.confirmPassword = false,
    this.emailFocusNode,
  });

  final String submitLabel;
  final bool isSubmitting;
  final bool confirmPassword;
  final FocusNode? emailFocusNode;
  final void Function(String email, String password) onSubmit;

  @override
  State<EmailPasswordForm> createState() => _EmailPasswordFormState();
}

class _EmailPasswordFormState extends State<EmailPasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Enter your email';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
      return 'Enter a valid email';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Enter your password';
    if (widget.confirmPassword && v.length < 8) {
      return 'Use at least 8 characters';
    }
    return null;
  }

  String? _validateConfirm(String? value) {
    if (!widget.confirmPassword) return null;
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  void _submit() {
    if (widget.isSubmitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    widget.onSubmit(_emailController.text.trim(), _passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    return AutofillGroup(
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Email address',
                style: AuthDesign.body(11, weight: 500),
              ),
            ),
            Semantics(
              label: 'Email address',
              child: TextFormField(
                focusNode: widget.emailFocusNode,
                controller: _emailController,
                enabled: !widget.isSubmitting,
                style: AuthDesign.body(12),
                autocorrect: false,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(hintText: 'you@example.com'),
                validator: _validateEmail,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Password', style: AuthDesign.body(11, weight: 500)),
                if (!widget.confirmPassword)
                  TextButton(
                    onPressed: widget.isSubmitting
                        ? null
                        : () => showPasswordResetDialog(
                            context,
                            _emailController.text.trim(),
                          ),
                    child: const Text('Forgot password?'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Semantics(
              label: 'Password',
              child: TextFormField(
                controller: _passwordController,
                enabled: !widget.isSubmitting,
                style: AuthDesign.body(12),
                autocorrect: false,
                enableSuggestions: false,
                obscureText: _obscure,
                textInputAction: widget.confirmPassword
                    ? TextInputAction.next
                    : TextInputAction.done,
                autofillHints: [
                  widget.confirmPassword
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                decoration: InputDecoration(
                  hintText: widget.confirmPassword
                      ? 'Create a password'
                      : 'Enter your password',
                  helperText: widget.confirmPassword
                      ? 'Use at least 8 characters'
                      : null,
                  suffixIcon: IconButton(
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: _validatePassword,
                onFieldSubmitted: widget.confirmPassword
                    ? null
                    : (_) => _submit(),
              ),
            ),
            if (widget.confirmPassword) ...[
              const SizedBox(height: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Confirm password',
                  style: AuthDesign.body(11, weight: 500),
                ),
              ),
              Semantics(
                label: 'Confirm password',
                child: TextFormField(
                  controller: _confirmController,
                  enabled: !widget.isSubmitting,
                  style: AuthDesign.body(12),
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Confirm your password',
                  ),
                  validator: _validateConfirm,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            AuthActionButton(
              label: widget.submitLabel,
              busy: widget.isSubmitting,
              primary: true,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
