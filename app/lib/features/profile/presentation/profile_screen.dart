import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Placeholder for `GetProfile` + a user's posts. Phase 0 only wires the
/// `/profile/:handle` route and navigation.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.handle});

  final String handle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('@$handle')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 32,
                child: Icon(Icons.person_outline, size: 32),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                '@$handle',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                "This profile's posts are coming soon.",
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
