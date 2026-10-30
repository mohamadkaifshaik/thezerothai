import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../data/messaging_repository.dart';
import '../../domain/messaging_feature_flag.dart';
import '../../domain/messaging_feature_gate.dart';

/// What Messages offers this caller right now (W7-26, ADR-0027 F6(a)), read
/// from the one seam, [MessagingFeatureGate.access].
///
/// - With `messaging` in `GetMe.enabled_features` it is [MessagingAccess.full].
/// - Otherwise it follows the gate: `readOnly` after this session's probe
///   succeeded, `hidden` before, or when no [MessagingRepository] is in scope.
/// - Rebuilds when the flag set changes (OnboardingBloc) or the gate changes
///   (the probe answered, or messaging turned out to be globally off).
///
/// The subtree keeps one shape in every mode, so a screen's cubits survive
/// `full` turning into `readOnly` and back.
class MessagingAccessBuilder extends StatelessWidget {
  const MessagingAccessBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, MessagingAccess access) builder;

  @override
  Widget build(BuildContext context) {
    final flagOn = isFeatureEnabled(context, kFeatureMessaging);
    MessagingFeatureGate? gate;
    try {
      gate = RepositoryProvider.of<MessagingRepository>(context).gate;
    } on Object {
      // No messaging stack in scope (a test, or a build without it).
      gate = null;
    }
    return ListenableBuilder(
      listenable: gate ?? const _NeverChanges(),
      builder: (context, _) => builder(
        context,
        flagOn
            ? MessagingAccess.full
            : (gate?.access ?? MessagingAccess.hidden),
      ),
    );
  }
}

class _NeverChanges implements Listenable {
  const _NeverChanges();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
