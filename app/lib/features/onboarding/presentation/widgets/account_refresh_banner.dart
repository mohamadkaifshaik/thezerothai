import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../shared/widgets/primitives/app_notice_banner.dart';
import '../bloc/onboarding_bloc.dart';
import '../bloc/onboarding_event.dart';

/// The copy of [AccountRefreshBanner].
const kAccountRefreshFailedMessage = "Couldn't refresh your account.";

/// Non-blocking notice over the shell while the last `GetMe` failed and a
/// cached profile keeps the app usable (`OnboardingState.refreshFailed`).
/// Retry dispatches [OnboardingRefreshRequested]; the banner goes away with
/// the next successful `GetMe`. Renders nothing otherwise, and nothing when no
/// onboarding flow is provided (a screen used standalone).
class AccountRefreshBanner extends StatelessWidget {
  const AccountRefreshBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final failed = context.select<OnboardingBloc?, bool>(
      (bloc) => bloc?.state.refreshFailed ?? false,
    );
    if (!failed) return const SizedBox.shrink();
    return AppNoticeBanner(
      message: kAccountRefreshFailedMessage,
      onRetry: () => context.read<OnboardingBloc>().add(
        const OnboardingRefreshRequested(),
      ),
    );
  }
}
