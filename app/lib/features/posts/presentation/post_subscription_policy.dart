import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../premium/domain/subscription_models.dart';
import '../../premium/presentation/bloc/subscription_cubit.dart';

// UI hints only. Each mutation is independently authorized by the Go API.
int subscriptionPostLimit(BuildContext context) {
  final state = context.read<SubscriptionCubit?>()?.state;
  // The subscription session is bound to the signed-in Firebase account
  // (authentication identity), not to the API user id, which is a
  // server-issued opaque string that can change kind with `public_ids`.
  final uid = context.read<AuthBloc?>()?.state.user?.uid;
  if (uid == null ||
      uid.isEmpty ||
      state?.uid != uid ||
      state?.access?.uid != uid) {
    return 280;
  }
  return switch (state?.access?.effectiveTier(DateTime.now())) {
    SubscriptionTier.premium => 15000,
    SubscriptionTier.plus => 15000,
    _ => 280,
  };
}

Stream<Object?>? subscriptionPostChanges(BuildContext context) =>
    context.read<SubscriptionCubit?>()?.stream;
