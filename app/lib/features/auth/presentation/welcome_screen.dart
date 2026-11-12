import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../../../shared/widgets/primitives/app_brand_mark.dart';
import '../../../shared/widgets/primitives/app_pill_button.dart';
import '../domain/auth_failure.dart';
import 'bloc/auth_bloc.dart';
import 'bloc/auth_event.dart';
import 'bloc/auth_state.dart';
import 'widgets/auth_page_layout.dart';
import 'widgets/social_sign_in_buttons.dart';

/// Where a signed-out visitor lands (the Main mocks): the same Google and
/// Apple sign-in as the forms, email on the sign-in page, and "Find your
/// people" on the sign-up page. Phone, tablet and desktop share the actions.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) => BlocConsumer<AuthBloc, AuthState>(
    listenWhen: (previous, current) => current.failure != null,
    listener: (context, state) {
      final failure = state.failure;
      if (failure == null || failure.message.isEmpty) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failure.message)));
      context.read<AuthBloc>().add(const AuthFailureDismissed());
    },
    builder: (context, state) {
      final theme = Theme.of(context);
      final bloc = context.read<AuthBloc>();
      final busy = state.isSubmitting;
      final phone =
          AuthLook.of(MediaQuery.sizeOf(context).width) == AuthLook.phone;
      return AuthFrame(
        eyebrow: 'Zero distance',
        headline: 'Make ',
        accent: 'nearby',
        headlineTail: ' happen.',
        heroEyebrow: 'Good things start with a plan',
        heroHeadline: 'Your plans\ndeserve ',
        heroAccent: 'company',
        mark: AppBrandMark(
          size: phone ? AppWelcomeLayout.markPhone : AppWelcomeLayout.markWide,
          radius: phone
              ? AppWelcomeLayout.markRadiusPhone
              : AppWelcomeLayout.markRadiusWide,
        ),
        phoneAction: const AuthAppearanceControl(),
        actions: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SocialSignInButtons(
              stacked: true,
              isSubmitting: busy,
              onGoogleTap: () => bloc.add(const AuthGoogleSignInRequested()),
              onAppleTap: () => bloc.add(const AuthAppleSignInRequested()),
            ),
            const AuthOrDivider(label: 'or keep it classic'),
            AppPillButton(
              label: 'Continue with Email',
              icon: Icons.mail_outline,
              size: AppButtonSize.large,
              onPressed: busy ? null : () => context.go(AppRouter.signInPath),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Center(child: PrivacyPolicyLink()),
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            AuthSwitchLine(
              prompt: 'New around here?',
              action: 'Find your people ↗',
              onPressed: busy ? null : () => context.go(AppRouter.signUpPath),
            ),
          ],
        ),
        children: [
          Text(
            'Share what you want to do. Someone nearby wants that too.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    },
  );
}
