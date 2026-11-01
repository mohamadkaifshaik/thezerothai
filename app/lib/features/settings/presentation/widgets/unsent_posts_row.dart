import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../shared/widgets/settings_group.dart';
import '../../../posts/presentation/bloc/unsent_posts_cubit.dart';
import '../../../posts/presentation/widgets/draft_dialogs.dart';

/// The title of the Settings row that deletes the account's unsent posts.
const kUnsentPostsRowTitle = 'Delete unsent posts on this device';

/// The snackbars after the row's action.
const kUnsentPostsDeleted = 'Unsent posts deleted from this device.';
const kUnsentPostsDeleteFailed =
    "Couldn't delete your unsent posts. Try again.";

/// "Delete unsent posts on this device" (W6-31, security L-5): the way to
/// remove the account's drafts when the `drafts` flag is off and `/drafts`
/// redirects Home, and a plain privacy control on a shared device when it is
/// on. The Settings list builds it only while this account has rows here
/// ([count] above 0); needs an [UnsentPostsCubit] above it. A tap asks first
/// (`showDiscardDraftsDialog`), then deletes this uid's rows; it never opens
/// `/drafts`. 0 RPCs.
class UnsentPostsRow extends StatelessWidget {
  const UnsentPostsRow({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => SettingsRow(
    icon: Icons.delete_sweep_outlined,
    title: kUnsentPostsRowTitle,
    subtitle: count == 1 ? '1 unsent post' : '$count unsent posts',
    showChevron: false,
    onTap: () => _delete(context),
  );

  Future<void> _delete(BuildContext context) async {
    final cubit = context.read<UnsentPostsCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDiscardDraftsDialog(context, count: count);
    if (!confirmed) return;
    final deleted = await cubit.deleteAll();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            deleted ? kUnsentPostsDeleted : kUnsentPostsDeleteFailed,
          ),
        ),
      );
  }
}
