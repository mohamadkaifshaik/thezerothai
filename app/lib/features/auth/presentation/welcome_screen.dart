import 'package:material_ui/material_ui.dart';
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
import 'widgets/session_ended_notice.dart';
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
      final frame = AuthFrame(
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
        phonePreview: const _PlanPreview(),
        actions: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SocialSignInButtons(
              stacked: true,
              highlightGoogle: phone,
              isSubmitting: busy,
              onGoogleTap: () => bloc.add(const AuthGoogleSignInRequested()),
              onAppleTap: () => bloc.add(const AuthAppleSignInRequested()),
            ),
            if (phone)
              const SizedBox(height: AppWelcomeLayout.providerGap)
            else
              const AuthOrDivider(label: 'or keep it classic'),
            AppPillButton(
              label: 'Continue with Email',
              icon: phone ? null : Icons.mail_outline,
              variant: phone
                  ? AppButtonVariant.outline
                  : AppButtonVariant.primary,
              size: AppButtonSize.large,
              onPressed: busy ? null : () => context.go(AppRouter.signInPath),
            ),
            if (phone)
              AuthSwitchLine(
                prompt: 'Already have an account?',
                action: 'Sign in',
                onPressed: busy ? null : () => context.go(AppRouter.signInPath),
              ),
            const SizedBox(height: AppSpacing.sm),
            const Center(child: PrivacyPolicyLink()),
            const SiteLinksRow(),
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
          if (state.signedOutByDeviceRemoval ||
              state.signedOutAfterOwnRemoval) ...[
            SessionEndedNotice(afterOwnRemoval: state.signedOutAfterOwnRemoval),
            const SizedBox(height: AppSpacing.sm),
          ],
          Text(
            'Share what you want to do. Someone nearby wants that too.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: phone
                  ? AppPalette.text2OnDark
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
      return phone
          ? Theme(
              data: buildAppTheme(brightness: Brightness.dark),
              child: frame,
            )
          : frame;
    },
  );
}

/// An illustration of the kind of plans people can share after signing in.
class _PlanPreview extends StatelessWidget {
  const _PlanPreview();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Transform.rotate(
              angle: -.07,
              child: const _ExamplePlan(
                background: AppPalette.darkContainerHighest,
                foreground: AppPalette.white,
                metadata: AppPalette.text2OnDark,
                activity: 'Coffee · Today 5:30 PM',
                title: 'Filter coffee & sketching',
                details: 'Indiranagar · 2 spots left',
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Transform.rotate(
              angle: .05,
              child: const _ExamplePlan(
                background: AppPalette.drawerTileTeal,
                foreground: AppPalette.navy,
                metadata: AppPalette.text2,
                activity: 'Badminton · Sat 7 AM',
                title: 'Doubles, all levels',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _ExamplePlan extends StatelessWidget {
  const _ExamplePlan({
    required this.background,
    required this.foreground,
    required this.metadata,
    required this.activity,
    required this.title,
    this.details,
  });

  final Color background;
  final Color foreground;
  final Color metadata;
  final String activity;
  final String title;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: AppWelcomeLayout.phonePreviewWidth,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.navBar,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(activity, style: text.bodySmall?.copyWith(color: metadata)),
          const SizedBox(height: AppSpacing.xs),
          Text(title, style: text.titleMedium?.copyWith(color: foreground)),
          if (details case final detail?) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(detail, style: text.bodySmall?.copyWith(color: metadata)),
          ],
        ],
      ),
    );
  }
}
