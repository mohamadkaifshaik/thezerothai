import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../premium/domain/subscription_models.dart';
import '../../premium/presentation/bloc/subscription_cubit.dart';

// UI hints only. Each mutation is independently authorized by the Go API.
int subscriptionPostLimit(BuildContext context) {
  final state = context.read<SubscriptionCubit?>()?.state;
  final uid = context.read<OnboardingBloc>().state.profile?.userId;
  if (uid == null ||
      uid.isEmpty ||
      state?.uid != uid ||
      state?.access?.uid != uid) {
    return 280;
  }
  return switch (state?.access?.effectiveTier(DateTime.now())) {
    SubscriptionTier.premium => 15000,
    SubscriptionTier.plus => 3000,
    _ => 280,
  };
}

Stream<Object?>? subscriptionPostChanges(BuildContext context) =>
    context.read<SubscriptionCubit?>()?.stream;
