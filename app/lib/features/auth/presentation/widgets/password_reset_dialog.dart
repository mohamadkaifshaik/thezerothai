import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/auth_repository.dart';
import '../bloc/password_reset_cubit.dart';
import 'auth_design.dart';

Future<void> showPasswordResetDialog(BuildContext context, String email) {
  final repository = context.read<AuthRepository>();
  return showDialog<void>(
    context: context,
    builder: (_) => BlocProvider(
      create: (_) => PasswordResetCubit(repository),
      child: _PasswordResetDialog(email: email),
    ),
  );
}

class _PasswordResetDialog extends StatefulWidget {
  const _PasswordResetDialog({required this.email});
  final String email;
  @override
  State<_PasswordResetDialog> createState() => _PasswordResetDialogState();
}

class _PasswordResetDialogState extends State<_PasswordResetDialog> {
  final _form = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.email);
  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _send() {
    if (_form.currentState?.validate() ?? false) {
      context.read<PasswordResetCubit>().send(_email.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<PasswordResetCubit, PasswordResetState>(
        builder: (context, state) => AlertDialog(
          title: const Text('Let’s get you back in.'),
          content: SizedBox(
            width: 320,
            child: state.sent
                ? const Text(
                    'If an account uses that email, you’ll receive a password reset link. Check your inbox and spam folder.',
                  )
                : Form(
                    key: _form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Enter your email to request a password reset link.',
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _email,
                          enabled: !state.busy,
                          autofocus: true,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'Email address',
                          ),
                          validator: (value) =>
                              RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                  .hasMatch(value?.trim() ?? '')
                              ? null
                              : 'Enter a valid email',
                          onFieldSubmitted: (_) => _send(),
                        ),
                        if (state.error != null) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              state.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(state.sent ? 'Done' : 'Cancel'),
            ),
            if (!state.sent)
              AuthActionButton(
                label: 'Send reset link',
                primary: true,
                busy: state.busy,
                onPressed: _send,
              ),
          ],
        ),
      );
}
