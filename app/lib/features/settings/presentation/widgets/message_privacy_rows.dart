import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/feature_flags/feature_flags.dart';
import '../../../../shared/widgets/primitives/settings_group.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../onboarding/data/identity_repository.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../data/own_privacy_store.dart';
import '../../domain/message_privacy.dart';
import '../bloc/message_privacy_cubit.dart';
import '../message_settings_messages.dart';
import 'settings_choice_row.dart';

/// Provides a [MessagePrivacyCubit] under [child] and shows its save
/// failures (a snackbar; a FEATURE_DISABLED answer also refreshes the flag
/// set). Without an [OwnPrivacyStore] or [IdentityRepository] in the tree (a
/// test harness), or nobody signed in, [child] gets no cubit and the
/// message-privacy controls stay hidden. Creating the cubit sends nothing.
class MessagePrivacyScope extends StatelessWidget {
  const MessagePrivacyScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final store = context.read<OwnPrivacyStore?>();
    final identity = context.read<IdentityRepository?>();
    final uid = context.select((AuthBloc bloc) => bloc.state.user?.uid);
    if (store == null || identity == null || uid == null || uid.isEmpty) {
      return child;
    }
    return BlocProvider<MessagePrivacyCubit>(
      key: ValueKey(uid),
      create: (context) => MessagePrivacyCubit(
        identityRepository: identity,
        store: store,
        uid: uid,
        onProfileUpdated: (profile) => context.read<OnboardingBloc>().add(
          OnboardingProfileUpdated(profile),
        ),
      ),
      child: BlocListener<MessagePrivacyCubit, MessagePrivacyState>(
        listenWhen: (before, after) =>
            after.error != null && before.serial != after.serial,
        listener: (context, state) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(content: Text(messagePrivacyErrorMessage(state.error!))),
            );
          // The flag turned off since GetMe listed it: refresh the flag set
          // (every other surface follows it).
          if (state.receiptsRefused || state.followingRefused) {
            context.read<OnboardingBloc>().add(
              const OnboardingRefreshRequested(),
            );
          }
        },
        child: child,
      ),
    );
  }
}

/// Which message-privacy controls the caller sees, from the server's value
/// (none known: none shown), the flags and the undo rule.
class MessagePrivacyVisibility {
  const MessagePrivacyVisibility({
    required this.readReceipts,
    required this.whoCanMessage,
  });

  static const none = MessagePrivacyVisibility(
    readReceipts: false,
    whoCanMessage: false,
  );

  final bool readReceipts;
  final bool whoCanMessage;

  bool get any => readReceipts || whoCanMessage;

  /// [messagingOn]: Messages fully usable for the caller (turning a setting
  /// on is pointless without it; turning one off always shows).
  static MessagePrivacyVisibility of(
    BuildContext context, {
    required bool messagingOn,
  }) {
    final receiptsFlag = isFeatureEnabled(context, kFeatureReadReceipts);
    final policyFlag = isFeatureEnabled(context, kFeatureDmPolicy);
    final state = context.select<MessagePrivacyCubit?, MessagePrivacyState?>(
      (cubit) => cubit?.state,
    );
    final confirmed = state?.confirmed;
    if (state == null || confirmed == null) return none;
    return MessagePrivacyVisibility(
      readReceipts: readReceiptsRowVisible(
        flagOn: receiptsFlag,
        messagingOn: messagingOn,
        value: confirmed.readReceipts,
        refused: state.receiptsRefused,
      ),
      whoCanMessage: whoCanMessageRowVisible(
        flagOn: policyFlag,
        messagingOn: messagingOn,
        value: confirmed.whoCanMessage,
        refused: state.followingRefused,
      ),
    );
  }
}

/// The "Read receipts" switch (F3). Shows the server's value; while a save
/// runs it stays on that value, disabled, until the server answers. Needs a
/// [MessagePrivacyCubit] with a confirmed value above it.
class ReadReceiptsRow extends StatelessWidget {
  const ReadReceiptsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MessagePrivacyCubit>().state;
    final confirmed = state.confirmed;
    if (confirmed == null) return const SizedBox.shrink();
    return SettingsRow(
      icon: Icons.done_all,
      title: kReadReceiptsTitle,
      subtitle: kReadReceiptsSubtitle,
      toggled: confirmed.readReceipts,
      onTap: state.busy
          ? null
          : () => context.read<MessagePrivacyCubit>().setReadReceipts(
              on: !confirmed.readReceipts,
            ),
    );
  }
}

/// "Who can message you" (F9): Everyone or People you follow, inline. Shows
/// the server's value; disabled while a save runs. With the flag off (or
/// refused) only Everyone is offered, so a "People you follow" account can
/// always go back (the undo rule).
class WhoCanMessageRow extends StatelessWidget {
  const WhoCanMessageRow({super.key, required this.followingAllowed});

  /// Whether "People you follow" may be chosen (the flag is on).
  final bool followingAllowed;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<MessagePrivacyCubit>().state;
    final confirmed = state.confirmed;
    if (confirmed == null) return const SizedBox.shrink();
    final current = confirmed.whoCanMessage;
    final offerFollowing = followingAllowed && !state.followingRefused;
    return SettingsChoiceRow<WhoCanMessage>(
      icon: Icons.forum_outlined,
      title: kWhoCanMessageTitle,
      selected: current,
      choices: [
        for (final who in WhoCanMessage.values)
          if (who == WhoCanMessage.everyone || who == current || offerFollowing)
            SettingsChoice(who, who.label),
      ],
      note: kWhoCanMessageNote,
      onSelected: state.busy
          ? null
          : (who) => context.read<MessagePrivacyCubit>().setWhoCanMessage(who),
    );
  }
}
