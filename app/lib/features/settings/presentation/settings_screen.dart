import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session_wiring.dart' show UnexpectedErrorReporter;
import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../core/router/app_router.dart';
import '../../../core/telemetry/telemetry_consent_copy.dart';
import '../../../core/telemetry/telemetry_consent_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/text_size_cubit.dart';
import '../../../core/theme/theme_mode_cubit.dart';
import '../../../core/widgets/privacy_policy_link.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../core/widgets/telemetry_consent_card.dart';
import '../../../shared/widgets/primitives/settings_group.dart';
import '../../account/presentation/account_feature_flags.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import '../../auth/presentation/request_sign_out.dart';
import '../../beacons/domain/beacons_feature_flag.dart';
import '../../graph/presentation/graph_feature_flags.dart';
import '../../messages/domain/messaging_feature_gate.dart';
import '../../messages/presentation/widgets/messaging_access_builder.dart';
import '../../notifications/presentation/notification_settings_messages.dart';
import '../../notifications/presentation/notification_settings_screen.dart';
import '../../onboarding/data/identity_repository.dart';
import '../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../onboarding/presentation/bloc/onboarding_event.dart';
import '../../posts/data/drafts_repository.dart';
import '../../posts/domain/posts_feature_flag.dart';
import '../../posts/presentation/bloc/unsent_posts_cubit.dart';
import '../../profile/domain/profile_edit_feature_flag.dart';
import '../domain/private_accounts_feature_flag.dart';
import '../domain/message_privacy.dart';
import '../domain/settings_categories.dart';
import 'bloc/message_privacy_cubit.dart';
import 'bloc/protect_posts_cubit.dart';
import 'message_settings_messages.dart';
import 'protect_posts_messages.dart';
import 'settings_up.dart';
import 'widgets/message_privacy_rows.dart';
import 'widgets/protect_posts_row.dart';
import 'widgets/scheduled_posts_row.dart';
import 'widgets/settings_choice_row.dart';
import 'widgets/telemetry_consent_row.dart';
import 'widgets/unsent_posts_row.dart';

/// Phase 0 settings: account info + sign out. Notification, privacy and
/// data-export settings (RequestAccountExport, DeleteAccount) land with the
/// account-settings feature. "Blocked accounts"/"Muted accounts" (graph
/// plan) only appear when the graph feature flag is on —
/// "Protect your posts" shows with `private_accounts` on,
/// and for an already protected account whatever the flag (the undo rule).
///
/// The rows are grouped into sections; a section whose rows are all gated
/// off is not shown at all.
///
/// On the tablet layout (`ui_shell` + `ui_tablet`, 600-1199dp; tablet plan
/// section 4.3) the same rows are sorted into [SettingsCategory]s instead,
/// and [categoryId] (the `c` query parameter) is the open one:
/// - band A (600-839): no category = the categories list; a category = its
///   page, pushed over the list;
/// - band B (840-1199): this route is the detail beside the shell's
///   [SettingsCategoriesPane]: no category = the placeholder; a category =
///   its page.
/// An unknown `c`, or a category with no visible rows, is the same as none.
/// Phones, desktop and the legacy layout ignore [categoryId].
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.categoryId});

  /// The `c` query parameter of `/settings` (tablet layout only).
  final String? categoryId;

  @override
  Widget build(BuildContext context) {
    // Published by the tablet shell only, so every other layout keeps the
    // page below exactly as before.
    final geometry = ShellGeometry.maybeOf(context);
    if (geometry != null && geometry.tablet) {
      return _SettingsTabletPage(
        category: settingsCategoryFromId(categoryId),
        split: geometry.band == ShellBand.expanded,
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      // The same ~600 dp column as the Home feed on wide screens.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppBreakpoints.mobile),
          child: const SettingsList(),
        ),
      ),
    );
  }
}

/// The empty detail pane of the master-detail layout (>= 1200dp, no page
/// chosen yet; on the tablet layout from 840dp, no category chosen). The
/// tablet one adds the settings icon above the line ([showIcon], tablet plan
/// section 3: "icon, one line").
class SettingsDetailPlaceholder extends StatelessWidget {
  const SettingsDetailPlaceholder({super.key, this.showIcon = false});

  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    const line = Text('Select a setting', textAlign: TextAlign.center);
    if (!showIcon) return const Center(child: line);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.settings_outlined,
                    size: AppSpacing.xxl,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                line,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The list pane of Settings on the tablet layout from 840dp (band B), built
/// by the shell beside the [SettingsScreen] detail: the categories, then
/// Sign out. [selected] (from the URL) is highlighted.
class SettingsCategoriesPane extends StatelessWidget {
  const SettingsCategoriesPane({super.key, this.selected});

  final SettingsCategory? selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Settings'),
      ),
      body: _SettingsRowsScope(
        builder: (context, {required showProtect, required messaging}) {
          final rows = _rowsFor(
            context,
            showProtect: showProtect,
            messaging: messaging,
            // The detail's rows navigate; the list opens categories only.
            open: context.go,
          );
          return _CategoriesList(
            rows: rows,
            selected: selected,
            open: context.go,
          );
        },
      ),
    );
  }
}

/// The detail pane of the desktop Settings (`ui_shell`, >= 1200dp), beside
/// the shell's [SettingsCategoriesPane]: the category of `/settings?c=<id>`
/// ([categoryId]), Your account when none is chosen (the desktop mock). A
/// row opens its page in this pane (`go`), as in tablet band B.
class SettingsDesktopDetail extends StatelessWidget {
  const SettingsDesktopDetail({super.key, this.categoryId});

  /// The `c` query parameter of `/settings`.
  final String? categoryId;

  @override
  Widget build(BuildContext context) {
    return _SettingsTabletPage(
      category: settingsCategoryFromId(categoryId),
      split: true,
      fallback: SettingsCategory.account,
    );
  }
}

/// Settings on the tablet layout: the categories list (band A), the
/// placeholder (band B) or one category's page.
class _SettingsTabletPage extends StatelessWidget {
  const _SettingsTabletPage({
    required this.category,
    required this.split,
    this.fallback,
  });

  final SettingsCategory? category;

  /// Band B: this page is the detail beside the categories pane.
  final bool split;

  /// The category shown when none is chosen (desktop: Your account, as the
  /// desktop mock); null shows the placeholder (band B) or the list (A).
  final SettingsCategory? fallback;

  @override
  Widget build(BuildContext context) {
    return _SettingsRowsScope(
      builder: (context, {required showProtect, required messaging}) {
        // Band B replaces the detail (`go`); band A pushes over the list.
        void open(String location) =>
            split ? context.go(location) : context.push(location);
        final rows = _rowsFor(
          context,
          showProtect: showProtect,
          messaging: messaging,
          open: open,
        );
        final chosen = this.category;
        final category = chosen == null || rows.of(chosen).isEmpty
            ? fallback
            : chosen;
        final categoryRows = category == null
            ? const <Widget>[]
            : rows.of(category);
        if (category == null || categoryRows.isEmpty) {
          if (split) return const SettingsDetailPlaceholder(showIcon: true);
          return Scaffold(
            appBar: AppBar(title: const Text('Settings')),
            body: _readable(_CategoriesList(rows: rows, open: open)),
          );
        }
        final body = category == SettingsCategory.notifications
            // The push switches load and save themselves (F6).
            ? const NotificationSettingsBody()
            : ListView(
                padding: EdgeInsets.only(
                  bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  for (final (title, groupRows) in rows.groupsOf(category))
                    if (groupRows.isNotEmpty)
                      SettingsGroup(
                        title: title,
                        rows: groupRows,
                        style: SettingsGroupStyle.flat,
                      ),
                ],
              );
        return Scaffold(
          appBar: AppBar(
            // Band B: the categories are beside it, so no back arrow (even
            // with a page under it after a resize). Band A: back to the
            // list; with nothing to pop (a typed URL), up goes to it.
            automaticallyImplyLeading: !split,
            leading: split
                ? null
                : settingsUpButton(context, AppRouter.settingsPath),
            title: Text(category.label),
          ),
          body: _readable(body),
        );
      },
    );
  }

  /// The reading column of the tablet layout: at most
  /// [AppSize.readableMax], centred; the bar above spans the pane.
  static Widget _readable(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppSize.readableMax),
      child: child,
    ),
  );
}

/// The categories that have rows, in the design's order, with Scheduled
/// posts (a full-screen page, never a selection) between Display and About,
/// then Sign out on its own, always last.
///
/// Drawn as the tablet / desktop mocks' list: "Search settings" on top, then
/// the categories as flat rows (no card); the open category ([selected]) is
/// tinted with the selection bar at its end. A search lists the categories
/// and rows whose title matches; a row result opens its category.
class _CategoriesList extends StatefulWidget {
  const _CategoriesList({
    required this.rows,
    required this.open,
    this.selected,
  });

  final _SettingsRows rows;
  final void Function(String location) open;
  final SettingsCategory? selected;

  static const _icons = {
    SettingsCategory.account: Icons.person_outline,
    SettingsCategory.privacy: Icons.shield_outlined,
    SettingsCategory.notifications: Icons.notifications_none,
    SettingsCategory.display: Icons.brightness_6_outlined,
    SettingsCategory.about: Icons.info_outline,
  };

  @override
  State<_CategoriesList> createState() => _CategoriesListState();
}

class _CategoriesListState extends State<_CategoriesList> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The title (and icon) a search matches a row by; null for a row without
  /// a known title.
  static (String, IconData?)? _titleOf(Widget row) => switch (row) {
    SettingsRow(:final title, :final icon) => (title, icon),
    SettingsChoiceRow(:final title, :final icon) => (title, icon),
    ProtectPostsRow() => (kProtectPostsTitle, null),
    ReadReceiptsRow() => (kReadReceiptsTitle, null),
    UnsentPostsRow() => (kUnsentPostsRowTitle, null),
    TelemetryConsentRow(:final kind) => (
      TelemetryConsentCopy.label(kind),
      null,
    ),
    ScheduledPostsRow() => (ScheduledPostsRow.title, null),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final selected = widget.selected;
    final indicator = context.appColors.selectedIndicator;
    Widget categoryRow(SettingsCategory category) {
      final row = SettingsRow(
        icon: _CategoriesList._icons[category]!,
        title: category.label,
        subtitle: rows.summary(category),
        selected: category == selected,
        onTap: () => widget.open(settingsCategoryLocation(category)),
      );
      if (category != selected) return row;
      return DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: BorderDirectional(
            end: BorderSide(
              color: indicator,
              width: AppSettingsLayout.selectedBarWidth,
            ),
          ),
        ),
        child: row,
      );
    }

    final visible = [
      for (final category in SettingsCategory.values)
        if (rows.of(category).isNotEmpty) category,
    ];
    final query = _query.trim().toLowerCase();
    final List<Widget> items;
    if (query.isEmpty) {
      items = [
        for (final category in visible)
          if (category != SettingsCategory.about) categoryRow(category),
        ?rows.scheduled,
        if (visible.contains(SettingsCategory.about))
          categoryRow(SettingsCategory.about),
      ];
    } else {
      bool matches(String title) => title.toLowerCase().contains(query);
      items = [
        for (final category in visible)
          if (matches(category.label)) categoryRow(category),
        if (rows.scheduled case final scheduled?
            when matches(ScheduledPostsRow.title))
          scheduled,
        for (final category in visible)
          for (final row in rows.of(category))
            if (_titleOf(row) case (final title, final icon)
                when matches(title) && title != category.label)
              SettingsRow(
                icon: icon ?? _CategoriesList._icons[category]!,
                title: title,
                subtitle: category.label,
                onTap: () => widget.open(settingsCategoryLocation(category)),
              ),
      ];
    }
    return ListView(
      padding: EdgeInsets.only(
        bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        _SettingsSearchField(
          controller: _search,
          onChanged: (value) => setState(() => _query = value),
        ),
        // Flat rows (no card): the mocks' category list.
        SettingsGroupScope(
          style: SettingsGroupStyle.flat,
          child: Column(children: items),
        ),
        if (query.isNotEmpty && items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(
              'No settings match your search',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (query.isEmpty)
          SettingsGroup(rows: [rows.signOut], style: SettingsGroupStyle.flat),
      ],
    );
  }
}

/// The "Search settings" pill of the tablet / desktop mocks (dz.css
/// `.search`): white, a hairline, fully rounded, a search icon.
class _SettingsSearchField extends StatelessWidget {
  const _SettingsSearchField({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSettingsLayout.searchBottom,
      ),
      child: Container(
        constraints: const BoxConstraints(
          minHeight: AppSettingsLayout.searchHeight,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSettingsLayout.searchPaddingH,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search,
              size: AppIconSize.md,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: AppSettingsLayout.searchGap),
            Expanded(
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  isCollapsed: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Search settings',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The grouped Settings rows. On phones and tablets a row pushes its page; in
/// the master-detail layout ([AppBreakpoints.tablet] and up, where the shell
/// shows this list beside the page) it replaces the detail pane instead, and
/// the row of the open page ([selectedPath]) is highlighted. (The tablet
/// layout, `ui_tablet`, sorts the same rows into categories instead; see
/// [SettingsScreen].)
class SettingsList extends StatelessWidget {
  const SettingsList({super.key, this.selectedPath});

  final String? selectedPath;

  @override
  Widget build(BuildContext context) {
    return _SettingsRowsScope(builder: _buildList);
  }

  Widget _buildList(
    BuildContext context, {
    required bool showProtect,
    required MessagingAccess messaging,
  }) {
    final masterDetail =
        MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
    void open(String path) =>
        masterDetail ? context.go(path) : context.push(path);
    bool selected(String path) => masterDetail && selectedPath == path;

    final rows = _rowsFor(
      context,
      showProtect: showProtect,
      messaging: messaging,
      open: open,
      selected: selected,
    );
    // Phones: the phone mock's raised cards. Wider (a layout without the
    // tablet categories): the tablet / desktop mocks' flat boxes.
    final phone = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    // Plus the floating bar's inset (`ui_shell`); 0 under the docked bar.
    final bottom = AppSpacing.lg + MediaQuery.paddingOf(context).bottom;
    return ListView(
      padding: phone
          ? EdgeInsets.fromLTRB(
              AppSettingsLayout.pagePaddingH,
              AppSettingsLayout.pagePaddingV,
              AppSettingsLayout.pagePaddingH,
              bottom,
            )
          : EdgeInsets.only(bottom: bottom),
      children: [
        for (final (title, rows) in rows.phoneGroups())
          if (rows.isNotEmpty)
            SettingsGroup(
              title: title,
              rows: rows,
              style: phone
                  ? SettingsGroupStyle.raised
                  : SettingsGroupStyle.flat,
            ),
      ],
    );
  }
}

/// The state every Settings layout's rows read: the device's unsent-posts
/// count and the protect switch's cubit, around a [builder] that is told
/// whether the protect row shows and the caller's Messages access. The flat
/// list, the categories and each category page all gate their rows here.
class _SettingsRowsScope extends StatelessWidget {
  const _SettingsRowsScope({required this.builder});

  final Widget Function(
    BuildContext context, {
    required bool showProtect,
    required MessagingAccess messaging,
  })
  builder;

  @override
  Widget build(BuildContext context) {
    // The message-privacy cubit (no RPC on creation) is above every row, so
    // the list, the categories and their summaries see the same values.
    return MessagePrivacyScope(child: Builder(builder: _withDrafts));
  }

  Widget _withDrafts(BuildContext context) {
    final list = MessagingAccessBuilder(
      builder: (context, access) => _withProtect(context, access),
    );
    // The count of this account's unsent posts on the device, so the
    // delete entry shows only while there are some (and stays reachable with
    // `drafts` off). No repository in the tree (a test harness) = no entry.
    final drafts = context.read<DraftsRepository?>();
    final uid = context.select((AuthBloc bloc) => bloc.state.user?.uid);
    if (drafts == null || uid == null || uid.isEmpty) return list;
    return BlocProvider<UnsentPostsCubit>(
      key: ValueKey(uid),
      create: (context) => UnsentPostsCubit(
        repository: drafts,
        uid: uid,
        onUnexpectedError: context.read<UnexpectedErrorReporter?>(),
      ),
      child: list,
    );
  }

  Widget _withProtect(BuildContext context, MessagingAccess access) {
    // The protect switch's cubit exists only when the row can show, so a
    // caller without the flag reads no IdentityRepository here.
    final isPrivate = context.select(
      (OnboardingBloc bloc) => bloc.state.profile?.isPrivate ?? false,
    );
    final candidate =
        isPrivate || isFeatureEnabled(context, kFeaturePrivateAccounts);
    if (!candidate) {
      return builder(context, showProtect: false, messaging: access);
    }
    return BlocProvider<ProtectPostsCubit>(
      create: (context) => ProtectPostsCubit(
        identityRepository: context.read<IdentityRepository>(),
        onProfileUpdated: (profile) => context.read<OnboardingBloc>().add(
          OnboardingProfileUpdated(profile),
        ),
      ),
      child: Builder(
        builder: (context) => builder(
          context,
          messaging: access,
          showProtect:
              isPrivate ||
              !context.select((ProtectPostsCubit c) => c.state.refused),
        ),
      ),
    );
  }
}

/// Every Settings row the caller may see, each null (or empty) when gated
/// off. One source for the flat groups and the tablet categories, so a row
/// can never show in one and not the other.
class _SettingsRows {
  const _SettingsRows({
    required this.messages,
    required this.email,
    required this.editProfile,
    required this.changeHandle,
    required this.scheduled,
    required this.appearance,
    required this.textSize,
    required this.protect,
    required this.telemetry,
    required this.blocked,
    required this.muted,
    required this.messageSettings,
    required this.readReceipts,
    required this.notifications,
    required this.export,
    required this.unsent,
    required this.communityRules,
    required this.privacyPolicy,
    required this.deleteAccount,
    required this.signOut,
    required this.plansOn,
  });

  final Widget? messages;
  final Widget? email;
  final Widget? editProfile;
  final Widget? changeHandle;
  final Widget? scheduled;
  final Widget appearance;
  final Widget? textSize;
  final Widget? protect;
  final List<Widget> telemetry;
  final Widget? blocked;
  final Widget? muted;
  final Widget? messageSettings;
  final Widget? readReceipts;
  final Widget? notifications;
  final Widget? export;
  final Widget? unsent;
  final Widget communityRules;
  final Widget privacyPolicy;
  final Widget? deleteAccount;
  final Widget signOut;

  /// `beacons` is on: the Notifications summary names Plans.
  final bool plansOn;

  /// The rows of [category]'s page (tablet plan section 4.3), in order.
  List<Widget> of(SettingsCategory category) => switch (category) {
    SettingsCategory.account => [
      ?email,
      ?editProfile,
      ?changeHandle,
      ?export,
      ?unsent,
      ?deleteAccount,
    ],
    SettingsCategory.privacy => [
      ?protect,
      ?blocked,
      ?muted,
      ?messageSettings,
      ?readReceipts,
      ...telemetry,
      ?messages,
    ],
    // Only decides whether the category shows: its page is the push
    // switches themselves (`NotificationSettingsBody`).
    SettingsCategory.notifications => [?notifications],
    SettingsCategory.display => [appearance, ?textSize],
    SettingsCategory.about => [communityRules, privacyPolicy],
  };

  /// [category]'s page as labelled boxes (the tablet / desktop mocks' "Your
  /// account": Profile, then Data). The same rows as [of], in the mocks'
  /// order.
  List<(String?, List<Widget>)> groupsOf(SettingsCategory category) =>
      switch (category) {
        SettingsCategory.account => [
          ('Profile', [?editProfile, ?changeHandle, ?email]),
          ('Data', [?export, ?unsent, ?deleteAccount]),
        ],
        _ => [(category.label, of(category))],
      };

  /// The phone page (dzeroth-mobile Settings mock): its four groups in its
  /// order, then Session. Rows the mock has no slot for sit in the closest
  /// group. The same rows as the categories, so none is lost.
  List<(String?, List<Widget>)> phoneGroups() => [
    ('Your account', [?editProfile, ?changeHandle, ?email]),
    (
      'Privacy & safety',
      [
        ?blocked,
        ?muted,
        ?messageSettings,
        ?readReceipts,
        ?protect,
        ...telemetry,
        ?messages,
      ],
    ),
    ('App', [appearance, ?textSize, ?notifications, ?scheduled]),
    ('Data', [?export, ?unsent, privacyPolicy, communityRules, ?deleteAccount]),
    ('Session', [signOut]),
  ];

  /// The categories list's subtitle for [category]: what its page holds,
  /// named only from the rows the caller sees (at most three).
  String summary(SettingsCategory category) {
    final parts = switch (category) {
      SettingsCategory.account => [
        if (editProfile != null) 'edit profile',
        if (changeHandle != null) 'handle',
        if (email != null) 'email',
        if (export != null || unsent != null || deleteAccount != null)
          'your data',
      ],
      SettingsCategory.privacy => [
        if (blocked != null) 'blocked and muted accounts',
        if (messageSettings != null || messages != null) 'messages',
        if (protect != null) 'protect your posts',
        if (readReceipts != null) 'read receipts',
        if (telemetry.isNotEmpty) 'usage data',
      ],
      SettingsCategory.notifications => [
        if (plansOn) 'plans',
        'mentions',
        'followers',
      ],
      SettingsCategory.display => [
        'appearance',
        if (textSize != null) 'text size',
      ],
      SettingsCategory.about => ['Privacy Policy', 'Community rules'],
    };
    final shown = parts.take(3).join(', ');
    if (shown.isEmpty) return shown;
    return shown[0].toUpperCase() + shown.substring(1);
  }
}

/// Builds the rows the caller may see. [open] navigates to a leaf page;
/// [selected] marks the row of the open page (the desktop master-detail).
_SettingsRows _rowsFor(
  BuildContext context, {
  required bool showProtect,
  required MessagingAccess messaging,
  required void Function(String path) open,
  bool Function(String path)? selected,
}) {
  bool isSelected(String path) => selected?.call(path) ?? false;

  final user = context.select((AuthBloc bloc) => bloc.state.user);
  final handle = context.select(
    (OnboardingBloc bloc) => bloc.state.profile?.handle ?? '',
  );
  final graphEnabled = isGraphEnabled(context);
  final profileEnabled = isFeatureEnabled(context, kFeatureProfileSnapshot);
  final lifecycleEnabled = isAccountLifecycleEnabled(context);
  final plansOn = isFeatureEnabled(context, kFeatureBeacons);
  // 0 without the cubit (no repository, nobody signed in).
  final unsentPosts = context.select<UnsentPostsCubit?, int>(
    (cubit) => cubit?.state ?? 0,
  );
  // The ROUTE needs only `posts` (a user dropped from the allowlist
  // may still list and cancel), but this ENTRY shows
  // only with both flags for now: the client cannot tell "globally off" from
  // "not in the allowlist" (both just leave `scheduled_posts` out of
  // `enabled_features`). Whether every posts user gets the row is a product
  // decision still open.
  final scheduledEnabled =
      isFeatureEnabled(context, kFeaturePosts) &&
      isFeatureEnabled(context, kFeatureScheduledPosts);
  // F3 / F9: the server's values (none known yet: no rows), the flags and
  // the undo rule decide (see `MessagePrivacyVisibility`).
  final privacy = MessagePrivacyVisibility.of(
    context,
    messagingOn: messaging == MessagingAccess.full,
  );
  final whoCanMessage = context.select<MessagePrivacyCubit?, WhoCanMessage?>(
    (cubit) => cubit?.state.confirmed?.whoCanMessage,
  );
  final textSize = context.select<TextSizeCubit?, AppTextSize?>(
    (cubit) => cubit?.state,
  );

  // The legacy chrome (no `ui_shell`) has no Messages tab, so Settings
  // carries the only entry. The new shell has the bar / rail destination.
  // Read-only Messages (off for this caller only, with a cached
  // conversation) keeps the row in both chromes: it is the only way in.
  final messagesEntry = switch (messaging) {
    MessagingAccess.full => !isFeatureEnabled(context, kFeatureUiShell),
    MessagingAccess.readOnly => true,
    MessagingAccess.hidden => false,
  };

  Widget external(IconData icon, String title, VoidCallback onTap) =>
      SettingsRow(
        icon: icon,
        title: title,
        trailing: Icon(
          Icons.open_in_new,
          size: AppIconSize.md,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onTap: onTap,
      );

  return _SettingsRows(
    messages: messagesEntry
        ? SettingsRow(
            icon: Icons.mail_outline,
            title: 'Messages',
            subtitle: 'Your inbox and message requests',
            onTap: () => context.push(AppRouter.messagesPath),
          )
        : null,
    email: user?.email != null
        ? SettingsRow(
            icon: Icons.email_outlined,
            title: 'Email',
            subtitle: user!.email!,
          )
        : null,
    editProfile: profileEnabled
        ? SettingsRow(
            icon: Icons.person_outline,
            title: 'Edit profile',
            selected: isSelected(AppRouter.editProfilePath),
            onTap: () => open(AppRouter.editProfilePath),
          )
        : null,
    changeHandle: profileEnabled
        ? SettingsRow(
            icon: Icons.alternate_email,
            title: 'Change handle',
            subtitle: handle.isEmpty ? null : '@$handle',
            selected: isSelected(AppRouter.changeHandlePath),
            onTap: () => open(AppRouter.changeHandlePath),
          )
        : null,
    // A full-screen page over the shell, also in master-detail and in the
    // tablet list (never a detail page; the selection stays).
    scheduled: scheduledEnabled ? const ScheduledPostsRow() : null,
    // The choices inline (the design), no sheet: 0 RPCs, applied at once.
    appearance: SettingsChoiceRow<ThemeMode>(
      icon: Icons.brightness_6_outlined,
      title: 'Appearance',
      selected: context.select((ThemeModeCubit cubit) => cubit.state),
      choices: [
        for (final mode in const [
          ThemeMode.system,
          ThemeMode.light,
          ThemeMode.dark,
        ])
          SettingsChoice(mode, themeModeLabel(mode)),
      ],
      onSelected: (mode) => context.read<ThemeModeCubit>().select(mode),
    ),
    // F7: device level, no flag. Absent without the cubit (a test harness).
    textSize: textSize == null
        ? null
        : SettingsChoiceRow<AppTextSize>(
            icon: Icons.format_size,
            title: 'Text size',
            selected: textSize,
            choices: [
              for (final size in AppTextSize.values)
                SettingsChoice(size, size.label),
            ],
            onSelected: (size) => context.read<TextSizeCubit>().select(size),
            // The device text is already at the cap: the choice changes
            // nothing visible, so say why (R4 review UX 10).
            note:
                AppTextSizeScope.systemScalerOf(context).scale(_capProbe) >=
                    kAppTextScaleCap * _capProbe
                ? 'Your device text size is already large.'
                : null,
          ),
    protect: showProtect ? const ProtectPostsRow() : null,
    // Only on Android, only while the kind's flag is on.
    telemetry: [
      for (final kind in TelemetryKind.values)
        if (telemetryRowVisible(context, kind)) TelemetryConsentRow(kind: kind),
    ],
    blocked: graphEnabled
        ? SettingsRow(
            icon: Icons.block_outlined,
            title: 'Blocked accounts',
            selected: isSelected(AppRouter.blockedAccountsPath),
            onTap: () => open(AppRouter.blockedAccountsPath),
          )
        : null,
    muted: graphEnabled
        ? SettingsRow(
            icon: Icons.volume_off_outlined,
            title: 'Muted accounts',
            selected: isSelected(AppRouter.mutedAccountsPath),
            onTap: () => open(AppRouter.mutedAccountsPath),
          )
        : null,
    messageSettings: privacy.whoCanMessage
        ? SettingsRow(
            icon: Icons.forum_outlined,
            title: kMessageSettingsTitle,
            subtitle: whoCanMessage?.label,
            selected: isSelected(AppRouter.messageSettingsPath),
            onTap: () => open(AppRouter.messageSettingsPath),
          )
        : null,
    readReceipts: privacy.readReceipts ? const ReadReceiptsRow() : null,
    notifications: notificationPrefsEnabled(context)
        ? SettingsRow(
            icon: Icons.notifications_none,
            title: kNotificationSettingsRowTitle,
            subtitle: plansOn
                ? 'Plans, mentions, followers'
                : 'Mentions, followers',
            selected: isSelected(AppRouter.notificationSettingsPath),
            onTap: () => open(AppRouter.notificationSettingsPath),
          )
        : null,
    export: lifecycleEnabled
        ? SettingsRow(
            icon: Icons.download_outlined,
            title: 'Download my data',
            selected: isSelected(AppRouter.exportDataPath),
            onTap: () => open(AppRouter.exportDataPath),
          )
        : null,
    // Whatever the `drafts` flag says, while rows are here.
    unsent: unsentPosts > 0 ? UnsentPostsRow(count: unsentPosts) : null,
    communityRules: external(
      Icons.rule_outlined,
      'Community rules',
      () => launchCommunityRules(context),
    ),
    privacyPolicy: external(
      Icons.privacy_tip_outlined,
      'Privacy Policy',
      () => launchPrivacyPolicy(context),
    ),
    deleteAccount: lifecycleEnabled
        ? SettingsRow(
            icon: Icons.delete_forever_outlined,
            title: 'Delete account',
            destructive: true,
            selected: isSelected(AppRouter.deleteAccountPath),
            onTap: () => open(AppRouter.deleteAccountPath),
          )
        : null,
    signOut: SettingsRow(
      icon: Icons.logout,
      title: 'Sign out',
      showChevron: false,
      onTap: () => unawaited(requestSignOut(context)),
    ),
    plansOn: plansOn,
  );
}

/// The font size the Text size row checks the device scale at (body text).
const double _capProbe = 14;
