import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';

/// Google + Apple sign-in buttons. Apple is only shown on iOS, macOS and web
/// per Apple's guidelines and the task brief (no phone/SMS, no Apple button
/// on Android).
class SocialSignInButtons extends StatelessWidget {
  const SocialSignInButtons({
    super.key,
    required this.isSubmitting,
    required this.onGoogleTap,
    required this.onAppleTap,
  });

  final bool isSubmitting;
  final VoidCallback onGoogleTap;
  final VoidCallback onAppleTap;

  bool get _showApple =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: isSubmitting ? null : onGoogleTap,
          icon: const Icon(Icons.g_mobiledata, size: 28),
          label: const Text('Continue with Google'),
        ),
        if (_showApple) ...[
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: isSubmitting ? null : onAppleTap,
            icon: const Icon(Icons.apple),
            label: const Text('Continue with Apple'),
          ),
        ],
      ],
    );
  }
}
