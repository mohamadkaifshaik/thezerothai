import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/primitives/app_rings.dart';
import '../../../../shared/widgets/primitives/pin_to_home.dart';
import '../../domain/lists_feature_flag.dart';
import '../bloc/list_detail_state.dart';
import 'list_row.dart';
import 'list_unavailable_view.dart';
import 'lists_page_chrome.dart';

/// The phone hero's round Back and menu buttons (the mock's 8 % pearl disc
/// with a 14 % pearl ring), 48 dp so the tap target holds.
final ButtonStyle kListHeroIconStyle = IconButton.styleFrom(
  minimumSize: const Size.square(AppSpacing.minTapTarget),
  foregroundColor: AppPalette.pearl,
  backgroundColor: AppPalette.pearl.withValues(
    alpha: AppListsLayout.heroIconFillAlpha,
  ),
  side: BorderSide(
    color: AppPalette.pearl.withValues(
      alpha: AppListsLayout.heroIconBorderAlpha,
    ),
  ),
);

/// The top of `/lists/:id` (the mocks' navy hero): the "List · Public" kicker,
/// the name as a display title with its last word in electric teal, the
/// description, the owner row, "N Members" and the Pin / Unpin and Edit List
/// buttons. Presentation only; the screen wires the callbacks.
///
/// - On a phone the hero also holds Back and the overflow menu ([onBack],
///   [menu]); the wide layouts put them in a top bar above it.
/// - Edit List is for the [isOwner] only; Pin / Unpin is for everyone who can
///   see the List. At [kMaxPinnedHomeTabs] pinned, Pin is disabled and a hint
///   says why. The buttons wrap, so they fit at 360 dp and text scale 2.0.
/// - Without a header (offline cold start) a plain "List" title shows, with
///   Retry when the one `GetList` fell through.
/// - Not built: the mocks' "Followers" count (no such field).
class ListDetailHeader extends StatelessWidget {
  const ListDetailHeader({
    super.key,
    required this.state,
    required this.isOwner,
    required this.onMembers,
    required this.onOwner,
    required this.onTogglePin,
    required this.onEdit,
    required this.onRetry,
    this.onBack,
    this.menu,
  });

  final ListDetailState state;
  final bool isOwner;
  final VoidCallback onMembers;
  final VoidCallback onOwner;
  final VoidCallback onTogglePin;
  final VoidCallback onEdit;
  final VoidCallback onRetry;

  /// The phone's Back, inside the hero.
  final VoidCallback? onBack;

  /// The phone's overflow menu (Report), inside the hero.
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final phone = isListsPhone(context);
    return DecoratedBox(
      key: const ValueKey('list-hero'),
      decoration: BoxDecoration(
        gradient: AppGradients.hero,
        borderRadius: phone
            ? null
            : const BorderRadius.vertical(
                bottom: Radius.circular(AppListsLayout.heroWideRadius),
              ),
      ),
      child: ClipRect(
        child: Stack(
          children: [
            if (!phone)
              Positioned.fill(
                child: AppRings(
                  rings: const [
                    (AppListsLayout.heroRingSize, AppListsLayout.heroRingAlpha),
                  ],
                  color: AppPalette.tealElectric,
                  centre: (size) => Offset(
                    size.width + AppListsLayout.heroRingOffsetX,
                    AppListsLayout.heroRingOffsetY,
                  ),
                ),
              ),
            DefaultTextStyle.merge(
              style: const TextStyle(color: AppPalette.pearl),
              child: IconTheme(
                data: const IconThemeData(color: AppPalette.pearl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (phone && onBack != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              style: kListHeroIconStyle,
                              tooltip: 'Back',
                              icon: const Icon(Icons.arrow_back),
                              onPressed: onBack,
                            ),
                            const Spacer(),
                            ?menu,
                          ],
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppListsLayout.heroGutter,
                        phone ? AppSpacing.sm : AppListsLayout.heroWideTop,
                        AppListsLayout.heroGutter,
                        phone
                            ? AppListsLayout.heroPhoneBottom
                            : AppListsLayout.heroWideBottom,
                      ),
                      child: _body(context, phone),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, bool phone) {
    final theme = Theme.of(context);
    final header = state.header;
    if (header == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('List', style: _titleStyle(theme, phone)),
          ),
          if (state.headerFailed)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppPalette.pearl),
              onPressed: onRetry,
              child: const Text("Couldn't load List details. Retry"),
            ),
        ],
      );
    }
    final hint = pinToHomeHint(
      pinned: state.pinned,
      full: state.pinFull,
      writeUnavailable: state.pinWriteUnavailable,
    );
    const muted = AppPalette.mutedOnDark;
    final bodySize = phone
        ? AppListsLayout.heroPhoneBody
        : AppListsLayout.heroWideBody;
    final owner = header.owner;
    final ownerName = owner.displayName.isEmpty
        ? '@${owner.handle}'
        : owner.displayName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'List · ${header.isPrivate ? 'Private' : 'Public'}'.toUpperCase(),
          style: AppTextStyles.eyebrow(theme)
              .copyWith(color: AppPalette.tealElectric),
        ),
        const SizedBox(height: AppSpacing.sm),
        Semantics(
          header: true,
          child: _Title(name: header.name, phone: phone),
        ),
        if (header.description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            header.description,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontSize: bodySize,
              color: muted,
            ),
          ),
        ],
        if (owner.userId.isNotEmpty)
          Semantics(
            button: true,
            label: 'List by $ownerName, @${owner.handle}',
            excludeSemantics: true,
            onTap: onOwner,
            child: InkWell(
              onTap: onOwner,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Row(
                  children: [
                    AppAvatar(url: owner.avatarUrl, radius: 12),
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(
                      child: Text(
                        ownerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: AppPalette.pearl,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(
                      child: Text(
                        '@${owner.handle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Semantics(
            button: true,
            label: listMemberCountLabel(header.memberCount),
            excludeSemantics: true,
            onTap: onMembers,
            child: InkWell(
              onTap: onMembers,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Align(
                  widthFactor: 1,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${header.memberCount}',
                          style: TextStyle(
                            fontSize: phone
                                ? AppListsLayout.heroPhoneStat
                                : AppListsLayout.heroWideStat,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.pearl,
                          ),
                        ),
                        TextSpan(
                          text: header.memberCount == 1
                              ? ' Member'
                              : ' Members',
                          style: TextStyle(fontSize: bodySize, color: muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Wrap(
          spacing: AppListsLayout.heroButtonGap,
          runSpacing: AppListsLayout.heroButtonGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PinToHomeButton(
              onDark: true,
              pinned: state.pinned,
              full: state.pinFull,
              writeUnavailable: state.pinWriteUnavailable,
              busy: state.pinBusy,
              onToggle: onTogglePin,
            ),
            if (isOwner)
              OutlinedButton(
                style: kListOnDarkOutlinedButtonStyle,
                onPressed: onEdit,
                child: const Text('Edit List'),
              ),
          ],
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
      ],
    );
  }

  static TextStyle? _titleStyle(ThemeData theme, bool phone) {
    final size = phone
        ? AppListsLayout.heroPhoneTitle
        : AppListsLayout.heroWideTitle;
    return theme.textTheme.displaySmall?.copyWith(
      fontSize: size,
      fontWeight: AppTypeTokens.weightDisplay,
      height: AppTypeTokens.displayLineHeight,
      letterSpacing: size * AppTypeTokens.displayTracking,
      color: AppPalette.pearl,
    );
  }
}

/// The name as the mocks' display title, its last word in electric teal
/// ("Coffee club" with "club" teal). No full stop is added: the name is
/// the owner's text, as on the plan hero.
class _Title extends StatelessWidget {
  const _Title({required this.name, required this.phone});

  final String name;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final style = ListDetailHeader._titleStyle(Theme.of(context), phone);
    final trimmed = name.trim();
    final cut = trimmed.lastIndexOf(' ') + 1;
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: trimmed.substring(0, cut)),
          TextSpan(
            text: trimmed.substring(cut),
            style: const TextStyle(color: AppPalette.tealElectric),
          ),
        ],
      ),
    );
  }
}
