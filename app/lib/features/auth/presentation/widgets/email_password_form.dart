import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_pill_button.dart';
import 'password_reset_dialog.dart';

/// Lays out the form's two parts; the page decides where the submit button
/// sits (pinned to the bottom on phones, under the fields on wider screens).
typedef EmailPasswordFormBuilder = Widget Function(
  BuildContext context,
  Widget fields,
  Widget submit,
);

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
    this.fieldIcons = false,
    this.dense = false,
    this.builder,
  });

  final String submitLabel;
  final bool isSubmitting;
  final bool confirmPassword;
  final FocusNode? emailFocusNode;
  final void Function(String email, String password) onSubmit;

  /// Mail and lock glyphs at the start of the fields (tablet and desktop).
  final bool fieldIcons;

  /// The phone mocks' tighter field rhythm.
  final bool dense;

  /// Defaults to the fields with the submit button under them.
  final EmailPasswordFormBuilder? builder;

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

  double get _gap =>
      widget.dense ? AppAuthLayout.phoneFieldGap : AppAuthLayout.fieldGap;

  Widget? _icon(IconData icon) =>
      widget.fieldIcons ? Icon(icon, size: AppIconSize.md) : null;

  Widget _field(String label, Widget field) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The field carries the same label for screen readers.
        ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: AppTypeTokens.weightLabel,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: AppAuthLayout.fieldLabelGap),
        Semantics(label: label, child: field),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          'Email address',
          TextFormField(
            focusNode: widget.emailFocusNode,
            controller: _emailController,
            enabled: !widget.isSubmitting,
            autocorrect: false,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(
              hintText: widget.confirmPassword
                  ? 'Enter your email'
                  : 'you@example.com',
              prefixIcon: _icon(Icons.mail_outline),
            ),
            validator: _validateEmail,
          ),
        ),
        SizedBox(height: _gap),
        _field(
          'Password',
          TextFormField(
            controller: _passwordController,
            enabled: !widget.isSubmitting,
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
                  ? 'At least 8 characters'
                  : null,
              prefixIcon: _icon(Icons.lock_outline),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: AppIconSize.md,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: _validatePassword,
            onFieldSubmitted: widget.confirmPassword ? null : (_) => _submit(),
          ),
        ),
        if (!widget.confirmPassword)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: context.appColors.accentText,
              ),
              onPressed: widget.isSubmitting
                  ? null
                  : () => showPasswordResetDialog(
                      context,
                      _emailController.text.trim(),
                    ),
              child: const Text('Forgot password?'),
            ),
          ),
        if (widget.confirmPassword) ...[
          SizedBox(height: _gap),
          _field(
            'Confirm password',
            TextFormField(
              controller: _confirmController,
              enabled: !widget.isSubmitting,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: 'Confirm your password',
                prefixIcon: _icon(Icons.lock_outline),
              ),
              validator: _validateConfirm,
              onFieldSubmitted: (_) => _submit(),
            ),
          ),
        ],
      ],
    );
    final submit = SizedBox(
      width: double.infinity,
      child: AppPillButton(
        label: widget.submitLabel,
        busy: widget.isSubmitting,
        size: AppButtonSize.large,
        onPressed: _submit,
      ),
    );
    final builder =
        widget.builder ??
        (context, fields, submit) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            fields,
            const SizedBox(height: AppSpacing.lg),
            submit,
          ],
        );
    return AutofillGroup(
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Builder(builder: (context) => builder(context, fields, submit)),
      ),
    );
  }
}
