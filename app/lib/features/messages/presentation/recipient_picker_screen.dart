import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/network/app_exception.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../shared/widgets/app_back_header.dart';
import '../../../shared/widgets/app_empty_view.dart';
import '../../../shared/widgets/user_list_skeleton.dart';
import '../../graph/data/graph_repository.dart';
import '../../graph/domain/graph_feature_flag.dart';
import '../../graph/presentation/bloc/user_list_cubit.dart';
import '../../graph/presentation/bloc/user_list_state.dart';
import '../../graph/presentation/widgets/paged_user_list.dart';
import '../../graph/presentation/widgets/user_list_row.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../domain/messaging_feature_flag.dart';
import '../domain/people_source.dart';
import 'bloc/recipient_picker_cubit.dart';
import 'messaging_error_messages.dart';
import 'open_conversation.dart';

/// The "To:" field's key.
const kRecipientFieldKey = ValueKey('recipient-field');

/// Key of the "Message @handle" row.
const kRecipientHandleRowKey = ValueKey('recipient-handle-row');

/// Shown when nobody the caller follows matches what is typed.
const kRecipientNoMatchText = 'No one you follow matches';

/// The page of `/messages/new` (W7-17): a modal on the root navigator. Full
/// screen below 600 dp; a centred card at most 600 dp wide from 600 dp.
class RecipientPickerPage extends Page<void> {
  const RecipientPickerPage({super.key, this.source});

  /// Where people come from; null = the caller's Following list. W4's search
  /// source plugs in here.
  final PeopleSource? source;

  @override
  Route<void> createRoute(BuildContext context) {
    return DialogRoute<void>(
      context: context,
      settings: this,
      barrierDismissible: true,
      barrierLabel: 'Close',
      builder: (context) => RecipientPickerDialog(source: source),
    );
  }
}

/// The frame of the picker: [Dialog.fullscreen] under 600 dp, a 600 dp card
/// above (as the Premium dialog). The content is [RecipientPicker].
class RecipientPickerDialog extends StatelessWidget {
  const RecipientPickerDialog({super.key, this.source, this.onPicked});

  final PeopleSource? source;
  final void Function(BuildContext context, common.AuthorSnapshot peer)?
  onPicked;

  @override
  Widget build(BuildContext context) {
    final picker = RecipientPicker(source: source, onPicked: onPicked);
    final size = MediaQuery.sizeOf(context);
    if (size.width < AppBreakpoints.mobile) {
      return Dialog.fullscreen(child: SafeArea(child: picker));
    }
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppLayout.mainColumnMaxWidth,
          maxHeight: math.max(
            AppSize.contentMax,
            size.height - 2 * AppSpacing.lg,
          ),
        ),
        child: SizedBox(
          height: math.min(size.height - 2 * AppSpacing.lg, 640),
          child: picker,
        ),
      ),
    );
  }
}

/// The new-message picker (W7-17, ADR-0027 D5): a "To:" field over a list of
/// people.
///
/// - Empty field: the people the caller follows (`ListFollowing` through the
///   [PeopleSource], paged, [UserListRow]s without a Follow button). Needs
///   `graph`; without it the list is replaced by a hint to type a handle.
/// - Typing, `search` on and a source that searches: the source's typeahead
///   (debounced, at least two characters). `search` off, or a source that
///   cannot search (today's only one): the loaded Following rows are filtered
///   in place (no request) and, for text that is a valid handle, a
///   "Message @handle" row resolves it with `GetProfile` on tap.
/// - Picking a person calls [onPicked]; the default replaces this page with
///   the existing conversation or a draft ([openConversationWith]).
/// - Needs `messaging`; without it, a short "not available" line.
class RecipientPicker extends StatelessWidget {
  const RecipientPicker({super.key, this.source, this.onPicked});

  /// Where people come from; defaults to the caller's Following list.
  final PeopleSource? source;

  /// Test seam / navigation: called with the chosen person.
  final void Function(BuildContext context, common.AuthorSnapshot peer)?
  onPicked;

  @override
  Widget build(BuildContext context) {
    if (!isFeatureEnabled(context, kFeatureMessaging)) {
      return Column(
        children: [
          AppBackHeader(
            title: 'New message',
            backTooltip: 'Close',
            onBack: () => _close(context),
          ),
          const Expanded(
            child: Center(
              child: AppEmptyView(
                icon: Icons.mail_outline,
                title: "Messages aren't available yet",
              ),
            ),
          ),
        ],
      );
    }
    return _PickerView(
      source: source,
      searchEnabled: isFeatureEnabled(context, kPickerSearchFlag),
      graphEnabled: isFeatureEnabled(context, kFeatureGraph),
      onPicked: onPicked,
    );
  }
}

void _close(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRouter.messagesPath);
  }
}

class _PickerView extends StatefulWidget {
  const _PickerView({
    required this.source,
    required this.searchEnabled,
    required this.graphEnabled,
    required this.onPicked,
  });

  final PeopleSource? source;
  final bool searchEnabled;
  final bool graphEnabled;
  final void Function(BuildContext, common.AuthorSnapshot)? onPicked;

  @override
  State<_PickerView> createState() => _PickerViewState();
}

class _PickerViewState extends State<_PickerView> {
  final _controller = TextEditingController();
  late final PeopleSource _source;
  late final UserListCubit _following;
  late final RecipientPickerCubit _picker;

  @override
  void initState() {
    super.initState();
    final ownUserId = context.read<OnboardingBloc>().state.profile?.userId;
    _source =
        widget.source ??
        FollowingPeopleSource(
          graphRepository: context.read<GraphRepository>(),
          userId: ownUserId ?? '',
        );
    _following = UserListCubit(fetchPage: _source.page);
    if (widget.graphEnabled) _following.loadFirstPage();
    _picker = RecipientPickerCubit(
      source: _source,
      identityRepository: context.read<IdentityRepository>(),
      searchEnabled: widget.searchEnabled,
      ownUserId: ownUserId,
      onUnexpectedError: context.read<UnexpectedErrorReporter>(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    unawaited(_following.close());
    unawaited(_picker.close());
    super.dispose();
  }

  void _pick(common.AuthorSnapshot peer) {
    final handler = widget.onPicked;
    if (handler != null) {
      handler(context, peer);
    } else {
      openConversationWith(context, peer, replace: true);
    }
  }

  Future<void> _pickHandle(String handle) async {
    final peer = await _picker.resolveHandle(handle);
    if (peer != null && mounted) _pick(peer);
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<UserListCubit>.value(value: _following),
        BlocProvider<RecipientPickerCubit>.value(value: _picker),
      ],
      child: Column(
        children: [
          AppBackHeader(
            title: 'New message',
            backTooltip: 'Close',
            onBack: () => _close(context),
          ),
          _ToField(
            controller: _controller,
            onChanged: _picker.queryChanged,
            onClear: () {
              _controller.clear();
              _picker.queryChanged('');
            },
          ),
          const _ResolveError(),
          const Divider(height: 1),
          Expanded(
            child: BlocBuilder<RecipientPickerCubit, RecipientPickerState>(
              builder: (context, state) => _body(state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(RecipientPickerState state) {
    final remote = state.remote;
    if (state.hasQuery && remote != null) return _remoteResults(remote);
    if (state.hasQuery && state.searching) {
      return const SingleChildScrollView(
        physics: NeverScrollableScrollPhysics(),
        child: UserListSkeleton(),
      );
    }
    final query = state.normalized;
    final candidate = state.hasQuery ? state.handleCandidate : null;
    return Column(
      children: [
        if (candidate != null)
          BlocBuilder<UserListCubit, UserListState>(
            builder: (context, following) {
              final listed = following.items.any(
                (i) => i.user.handle.toLowerCase() == candidate,
              );
              return listed
                  ? const SizedBox.shrink()
                  : _HandleRow(
                      handle: candidate,
                      busy: state.resolving,
                      onTap: () => _pickHandle(candidate),
                    );
            },
          ),
        Expanded(
          child: widget.graphEnabled
              ? PagedUserList(
                  cubit: _following,
                  emptyIcon: Icons.mail_outline,
                  emptyMessage: state.hasQuery
                      ? kRecipientNoMatchText
                      : "You're not following anyone yet. Type a handle to "
                            'message someone.',
                  itemFilter: state.hasQuery
                      ? (item) => _matches(item.user, query)
                      : null,
                  rowBuilder: (context, item) => _PickerRow(
                    key: ValueKey(item.user.userId),
                    item: item,
                    onTap: () => _pick(item.user),
                  ),
                )
              : (candidate != null
                    ? const SizedBox.shrink()
                    : const Center(
                        child: AppEmptyView(
                          icon: Icons.alternate_email,
                          title: 'Type a handle',
                          subtitle: 'Enter the @handle of the person.',
                        ),
                      )),
        ),
      ],
    );
  }

  Widget _remoteResults(List<graph.UserListItem> rows) {
    if (rows.isEmpty) {
      return const Center(
        child: AppEmptyView(icon: Icons.search_off, title: 'No people found'),
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final item = rows[index];
        return _PickerRow(
          key: ValueKey(item.user.userId),
          item: item,
          onTap: () => _pick(item.user),
        );
      },
    );
  }
}

bool _matches(common.AuthorSnapshot user, String query) =>
    user.handle.toLowerCase().contains(query) ||
    user.displayName.toLowerCase().contains(query);

/// "To:" and the text field.
class _ToField extends StatelessWidget {
  const _ToField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        start: AppSpacing.md,
        end: AppSpacing.xs,
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Text(
              'To:',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: AppSpacing.minTapTarget,
              ),
              child: TextField(
                key: kRecipientFieldKey,
                controller: controller,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                keyboardType: TextInputType.text,
                style: theme.textTheme.bodyLarge,
                onChanged: onChanged,
                decoration: InputDecoration(
                  labelText: null,
                  hintText: 'Search people or type a handle',
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox(width: AppSpacing.minTapTarget)
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close, size: AppIconSize.md),
                    onPressed: onClear,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The inline answer of a failed "Message @handle" resolve.
class _ResolveError extends StatelessWidget {
  const _ResolveError();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RecipientPickerCubit, RecipientPickerState>(
      buildWhen: (a, b) => a.resolveError != b.resolveError,
      builder: (context, state) {
        final error = state.resolveError;
        if (error == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Text(
                _resolveErrorText(error, state.handleCandidate),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One answer for a missing, suspended or blocking account (the server's
/// NOT_FOUND is identical for all three).
String _resolveErrorText(AppException error, String? handle) => switch (error) {
  NotFoundException() =>
    handle == null
        ? "We couldn't find that person."
        : "We couldn't find @$handle.",
  ValidationException() => error.message,
  _ => messagingErrorMessage(error),
};

/// A [UserListRow] without a Follow button that opens the person on tap: one
/// button for a screen reader ("Name, @handle"), at least 48dp tall.
class _PickerRow extends StatelessWidget {
  const _PickerRow({super.key, required this.item, required this.onTap});

  final graph.UserListItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final user = item.user;
    final name = user.displayName.isEmpty
        ? '@${user.handle}'
        : user.displayName;
    return Semantics(
      button: true,
      label: user.displayName.isEmpty
          ? 'Message $name'
          : 'Message $name, @${user.handle}',
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: UserListRow(item: item, trailing: const SizedBox.shrink()),
      ),
    );
  }
}

/// "Message @handle" for text that is a valid handle and not in the loaded
/// Following rows; resolved with `GetProfile` on tap.
class _HandleRow extends StatelessWidget {
  const _HandleRow({
    required this.handle,
    required this.busy,
    required this.onTap,
  });

  final String handle;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: true,
      enabled: !busy,
      label: 'Message @$handle',
      excludeSemantics: true,
      onTap: busy ? null : onTap,
      child: InkWell(
        key: kRecipientHandleRowKey,
        onTap: busy ? null : onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.surfaceContainerHigh,
                      ),
                      child: const SizedBox(
                        width: AppSpacing.xl + AppSpacing.sm,
                        height: AppSpacing.xl + AppSpacing.sm,
                        child: Icon(Icons.mail_outline, size: AppIconSize.lg),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'Message @$handle',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    if (busy)
                      const SizedBox(
                        width: AppIconSize.md,
                        height: AppIconSize.md,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }
}
