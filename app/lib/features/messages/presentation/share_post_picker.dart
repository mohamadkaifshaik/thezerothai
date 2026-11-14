import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/widgets/tablet_modal.dart';
import '../../graph/data/graph_repository.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../data/messaging_repository.dart';
import '../domain/messaging_feature_flag.dart';
import '../domain/people_source.dart';
import '../domain/share_post_target.dart';
import 'recipient_picker_screen.dart';

/// Whether the caller may send a post in a message: `messaging` and
/// `dm_post_share` are both in `GetMe.enabled_features`. The share menu shows
/// its "Send in a message" row only then. Reactive (call it from `build`).
bool sharePostInMessageAllowed(BuildContext context) =>
    isFeatureEnabled(context, kFeatureMessaging) &&
    isFeatureEnabled(context, kFeatureDmPostShare);

/// Opens the "Send in a message" picker for [target] as a dialog on the root
/// navigator: full screen on a phone, a card from 600 dp, placed on the
/// content area when the tablet or desktop layout is on
/// ([TabletModalHost]). Completes when it is closed.
///
/// [source] is where people come from (the caller's Following list when null;
/// a test seam, as on `RecipientPickerPage`).
///
/// Everything the picker reads is taken from [context] now and handed down,
/// because the dialog is built under the root navigator, which the card that
/// opened it may not share with its providers.
Future<void> showSharePostPicker(
  BuildContext context, {
  required SharePostTarget target,
  PeopleSource? source,
}) {
  final host = TabletModalHost.of(context);
  final onboarding = context.read<OnboardingBloc>();
  final messaging = context.read<MessagingRepository>();
  final graph = context.read<GraphRepository>();
  final identity = context.read<IdentityRepository>();
  final reporter = context.read<UnexpectedErrorReporter>();
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    useSafeArea: host == null,
    barrierDismissible: true,
    barrierLabel: 'Close',
    builder: (dialogContext) {
      final dialog = MultiRepositoryProvider(
        providers: [
          BlocProvider<OnboardingBloc>.value(value: onboarding),
          RepositoryProvider<MessagingRepository>.value(value: messaging),
          RepositoryProvider<GraphRepository>.value(value: graph),
          RepositoryProvider<IdentityRepository>.value(value: identity),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: reporter),
        ],
        child: RecipientPickerDialog(share: target, host: host, source: source),
      );
      return host == null
          ? dialog
          : TabletModalScope(host: host, child: dialog);
    },
  );
}
