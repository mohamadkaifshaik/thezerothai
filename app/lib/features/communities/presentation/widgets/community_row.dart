import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import '../../../../shared/widgets/primitives/app_card.dart';
import '../../../../shared/widgets/primitives/app_status_pill.dart';
import '../../../../shared/widgets/primitives/app_tile_icon.dart';
import '../../../lists/presentation/widgets/list_row.dart'
    show listMemberCountLabel;
import '../../domain/community_role.dart';

/// "1 member" / "N members" for a community (`member_count` is an Int64).
String communityMemberCountLabel(pb.Community community) =>
    listMemberCountLabel(community.memberCount.toInt());

/// The role badge text of [role] for the owner and moderators; null for a
/// plain member, a banned viewer or no role (the badge marks authority only).
String? communityRoleBadge(CommunityRole role) => switch (role) {
  CommunityRole.owner => 'Owner',
  CommunityRole.moderator => 'Moderator',
  _ => null,
};

/// One community in a list: the default tile, a bold name, a muted
/// "N members", a role badge for the owner and moderators, and an optional
/// [trailing] control (the Join / Joined pill of the lists). A custom row (no
/// `ListTile`); the whole text area is the tap target (>= 48dp) and speaks
/// name, members and role as one label. The audience picker reuses it
/// without [trailing], with [role] `menuItem` and [selected] for the chosen
/// one.
class CommunityRow extends StatelessWidget {
  const CommunityRow({
    super.key,
    required this.community,
    this.onTap,
    this.trailing,
    this.role,
    this.selected,
    this.card = false,
    this.wide = false,
  });

  final pb.Community community;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// The Communities page's look (dz.css `.card.row`, R10): the row on a
  /// raised card with a tile, the description (when there is one) under the
  /// name, then "N members". Off: the plain row (the composer's audience
  /// picker).
  final bool card;

  /// The tablet and desktop size of a [card] row: the 64 dp tile, the 17 sp
  /// name and the 16 / 18 padding of their mocks (the phone's are 52 dp,
  /// the title style and 14 dp).
  final bool wide;

  /// An ARIA role for the row on the web (null: a plain button).
  final SemanticsRole? role;

  /// Non-null makes the row one choice of a mutually exclusive group (spoken
  /// as selected or not).
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final members = communityMemberCountLabel(community);
    final badge = communityRoleBadge(community.role);
    final description = card ? community.description.trim() : '';
    final spoken = [
      community.name,
      if (description.isNotEmpty) description,
      members,
      ?badge,
    ].join(', ');
    final trailing = this.trailing;
    if (card) return _card(context, spoken, description, members, badge);
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: onTap != null,
            role: role,
            selected: selected,
            inMutuallyExclusiveGroup: selected == null ? null : true,
            label: spoken,
            excludeSemantics: true,
            onTap: onTap,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: AppSpacing.minTapTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.smd,
                  ),
                  child: Row(
                    children: [
                      const AppTileIcon(icon: Icons.groups_outlined),
                      const SizedBox(width: AppSpacing.smd),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              community.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  members,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: muted,
                                  ),
                                ),
                                if (badge != null) AppStatusPill(label: badge),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: AppSpacing.md),
            child: trailing,
          ),
      ],
    );
  }

  /// Above this text scale a [card] row puts its [trailing] pill under the
  /// name: at 2.0 a "Joined" pill alone is about 200 dp wide, which would
  /// leave a 320 dp phone's name no room (as band B's pane does, T8a).
  static const double cardStackTextScale = 1.3;

  /// At any text scale, a [card] row also puts its pill under the name when
  /// the pill beside it would leave the name less than this (R10 review
  /// item 14).
  static const double cardMinNameWidth = 140;

  /// The [card] look: the text area is the row's one button (as the plain
  /// row), the [trailing] pill sits beside it on the card (under the name at
  /// large text), never inside it.
  Widget _card(
    BuildContext context,
    String spoken,
    String description,
    String members,
    String? badge,
  ) {
    final theme = Theme.of(context);
    final colors = context.appColors;
    final radius = BorderRadius.circular(AppRadius.card);
    final trailing = this.trailing;
    final stack =
        trailing != null &&
        MediaQuery.textScalerOf(context).scale(1) > cardStackTextScale;
    final tileSize = wide
        ? AppCommunitiesLayout.cardTileWide
        : AppCommunitiesLayout.cardTilePhone;
    final insetV = wide
        ? AppCommunitiesLayout.cardPaddingVWide
        : AppCommunitiesLayout.cardPaddingPhone;
    final insetH = wide
        ? AppCommunitiesLayout.cardPaddingHWide
        : AppCommunitiesLayout.cardPaddingPhone;
    final textArea = Semantics(
      button: onTap != null,
      role: role,
      selected: selected,
      inMutuallyExclusiveGroup: selected == null ? null : true,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              insetH,
              insetV,
              AppSpacing.smd,
              insetV,
            ),
            child: Row(
              children: [
                AppTileIcon(icon: Icons.groups_outlined, size: tileSize),
                const SizedBox(width: AppSpacing.smd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        community.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: wide
                              ? AppCommunitiesLayout.cardNameWide
                              : null,
                        ),
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.secondaryOnRaised,
                          ),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            members,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          if (badge != null) AppStatusPill(label: badge),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm - AppSpacing.xs / 2,
      ),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: trailing == null
              ? textArea
              : _SideOrBelow(
                  below: stack,
                  // The text area's inset, tile, gap and end padding, plus
                  // the name's least width.
                  minMainWidth:
                      insetH +
                      tileSize +
                      AppSpacing.smd +
                      AppSpacing.smd +
                      cardMinNameWidth,
                  endGap: AppSpacing.smd,
                  // Under the name: the inset, the tile and its gap.
                  belowStart: insetH + tileSize + AppSpacing.smd,
                  belowBottom: AppSpacing.sm,
                  textDirection: Directionality.of(context),
                  main: textArea,
                  side: trailing,
                ),
        ),
      ),
    );
  }
}

/// The card row's text area ([main]) with its pill ([side]): beside it at
/// the end, vertically centred (a `Row`), or under the name ([belowStart]
/// from the start) when [below] is set or when the pill beside it would
/// leave [main] less than [minMainWidth]. The pill is measured first, so
/// the choice follows its real width at the ambient text scale and font.
class _SideOrBelow extends MultiChildRenderObjectWidget {
  _SideOrBelow({
    required this.below,
    required this.minMainWidth,
    required this.endGap,
    required this.belowStart,
    required this.belowBottom,
    required this.textDirection,
    required Widget main,
    required Widget side,
  }) : super(children: [main, side]);

  final bool below;
  final double minMainWidth;
  final double endGap;
  final double belowStart;
  final double belowBottom;
  final TextDirection textDirection;

  @override
  _RenderSideOrBelow createRenderObject(BuildContext context) =>
      _RenderSideOrBelow()
        ..below = below
        ..minMainWidth = minMainWidth
        ..endGap = endGap
        ..belowStart = belowStart
        ..belowBottom = belowBottom
        ..textDirection = textDirection;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSideOrBelow renderObject,
  ) {
    renderObject
      ..below = below
      ..minMainWidth = minMainWidth
      ..endGap = endGap
      ..belowStart = belowStart
      ..belowBottom = belowBottom
      ..textDirection = textDirection;
  }
}

class _SideOrBelowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderSideOrBelow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _SideOrBelowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _SideOrBelowParentData> {
  bool _below = false;
  set below(bool v) {
    if (v == _below) return;
    _below = v;
    markNeedsLayout();
  }

  double _minMainWidth = 0;
  set minMainWidth(double v) {
    if (v == _minMainWidth) return;
    _minMainWidth = v;
    markNeedsLayout();
  }

  double _endGap = 0;
  set endGap(double v) {
    if (v == _endGap) return;
    _endGap = v;
    markNeedsLayout();
  }

  double _belowStart = 0;
  set belowStart(double v) {
    if (v == _belowStart) return;
    _belowStart = v;
    markNeedsLayout();
  }

  double _belowBottom = 0;
  set belowBottom(double v) {
    if (v == _belowBottom) return;
    _belowBottom = v;
    markNeedsLayout();
  }

  TextDirection _textDirection = TextDirection.ltr;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _SideOrBelowParentData) {
      child.parentData = _SideOrBelowParentData();
    }
  }

  RenderBox get _main => firstChild!;
  RenderBox get _side => lastChild!;

  /// Lays out (or, with [dry], measures) both children; returns the size
  /// and, when laying out, places them.
  Size _layout(
    BoxConstraints constraints,
    Size Function(RenderBox child, BoxConstraints c) size, {
    required bool place,
  }) {
    final width = constraints.maxWidth;
    final sideSize = size(
      _side,
      BoxConstraints(
        maxWidth: (width - _belowStart - _endGap).clamp(0, double.infinity),
      ),
    );
    final mainWidth = width - sideSize.width - _endGap;
    final below = _below || mainWidth < _minMainWidth;
    final ltr = _textDirection == TextDirection.ltr;
    if (!below) {
      final mainSize = size(
        _main,
        BoxConstraints(minWidth: mainWidth, maxWidth: mainWidth),
      );
      final height = mainSize.height > sideSize.height
          ? mainSize.height
          : sideSize.height;
      if (place) {
        _offset(
          _main,
          Offset(
            ltr ? 0 : sideSize.width + _endGap,
            (height - mainSize.height) / 2,
          ),
        );
        _offset(
          _side,
          Offset(ltr ? mainWidth : _endGap, (height - sideSize.height) / 2),
        );
      }
      return constraints.constrain(Size(width, height));
    }
    final mainSize = size(
      _main,
      BoxConstraints(minWidth: width, maxWidth: width),
    );
    if (place) {
      _offset(_main, Offset.zero);
      _offset(
        _side,
        Offset(
          ltr ? _belowStart : width - _belowStart - sideSize.width,
          mainSize.height,
        ),
      );
    }
    return constraints.constrain(
      Size(width, mainSize.height + sideSize.height + _belowBottom),
    );
  }

  void _offset(RenderBox child, Offset offset) =>
      (child.parentData! as _SideOrBelowParentData).offset = offset;

  @override
  void performLayout() {
    size = _layout(constraints, (child, c) {
      child.layout(c, parentUsesSize: true);
      return child.size;
    }, place: true);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, (child, c) => child.getDryLayout(c), place: false);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
