import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/telemetry/analytics_event.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import '../../../../shared/widgets/primitives/app_avatar.dart';
import '../../../../shared/widgets/user/follow_button.dart';
import '../../../../shared/widgets/user/protected_badge.dart';
import '../../data/graph_repository.dart';
import '../bloc/relationship_cubit.dart';
import '../bloc/relationship_state.dart';

/// One row in any graph user list (followers, following, blocked, muted) and
/// in the "Who to follow" card.
///
/// The [FollowButton] (when [trailing] is not supplied) is seeded directly
/// from `item.relationship` — the server fills it from the caller's own
/// graph at 0 extra reads — so a page of rows never triggers a
/// `GetRelationships` call.
class UserListRow extends StatelessWidget {
  const UserListRow({
    super.key,
    required this.item,
    this.trailing,
    this.onProfileTap,
    this.onFollowed,
    this.onGone,
    this.onDismiss,
    this.showDivider = true,
    this.extraAction,
    this.followSource = FollowSource.list,
    this.avatarRadius = 20,
    this.horizontalInset = AppSpacing.md,
    this.verticalInset = AppSpacing.sm,
    this.handleStyle,
  });

  /// Merged over the @handle line's style (the community members page draws
  /// the design's 13 sp).
  final TextStyle? handleStyle;

  /// The row's top and bottom padding; the community members page uses the
  /// design's 12.
  final double verticalInset;

  /// The avatar's radius (dp); the default 20 is the list standard. The
  /// community members page draws the design's 44 dp avatar (22).
  final double avatarRadius;

  /// The row's start padding, and its end padding too unless [onDismiss]
  /// shows the dismiss button (the end is then `AppSpacing.xs`); the
  /// community members page uses the design's 20.
  final double horizontalInset;

  /// Where the row is shown, for the `follow` usage event.
  final FollowSource followSource;

  /// A second control after the follow button (or the trailing one), measured
  /// with it (the List members page: Remove for the owner).
  final Widget? extraAction;

  final graph.UserListItem item;

  /// Opts a browsing surface into profile navigation. Selection surfaces
  /// (such as the message recipient picker) keep their existing row action.
  final VoidCallback? onProfileTap;

  /// Overrides the default [FollowButton] trailing widget (e.g. an
  /// Unblock/Unmute action button in Settings' managed-accounts screens).
  final Widget? trailing;

  /// Called once the server confirmed a follow made from the default
  /// [FollowButton] (the state is FOLLOWING or REQUESTED, not updating, no
  /// error). Not called for the optimistic step, so a rejected follow rolls
  /// back and shows its message in the row; a caller that removes the row on
  /// this call never loses the rollback. Ignored with a [trailing].
  final VoidCallback? onFollowed;

  /// Called, once and with no message, when the follow is refused with
  /// NOT_FOUND: the account is blocked, suspended or deleted (the server
  /// answers the same for all three, L-1). A caller that offers
  /// accounts, like the "Who to follow" card, removes the row on this call.
  /// Ignored with a [trailing].
  final VoidCallback? onGone;

  /// Shows a 48dp "x" after the control and calls this when it is tapped
  /// (the "Who to follow" card's local dismiss).
  final VoidCallback? onDismiss;

  /// The hairline under the row; a card turns it off for its last row.
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final user = item.user;
    final theme = Theme.of(context);
    final onFollowed = this.onFollowed;
    final onGone = this.onGone;
    final onDismiss = this.onDismiss;
    final control =
        trailing ??
        BlocProvider(
          create: (context) => RelationshipCubit(
            graphRepository: context.read<GraphRepository>(),
            userId: user.userId,
            initial: graph.Relationship(
              userId: user.userId,
              followState: item.relationship.followState,
              blocking: item.relationship.blocking,
              muting: item.relationship.muting,
            ),
          ),
          child: onFollowed == null
              ? FollowButton(onGone: onGone, source: followSource)
              : BlocListener<RelationshipCubit, RelationshipState>(
                  listenWhen: (before, after) =>
                      after.isConfirmedFollow && !before.isConfirmedFollow,
                  listener: (context, state) => onFollowed(),
                  child: FollowButton(onGone: onGone, source: followSource),
                ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          link: onProfileTap != null,
          child: InkWell(
            onTap: onProfileTap,
            child: Padding(
              // Directional, so RTL mirrors the gaps (T8b review note).
              padding: EdgeInsetsDirectional.only(
                start: horizontalInset,
                end: onDismiss == null ? horizontalInset : AppSpacing.xs,
                top: verticalInset,
                bottom: verticalInset,
              ),
              // The control keeps its natural width at the user's text
              // scale and the name column gives way first; only when the name
              // column would drop under [_minNameColumnWidth] does the control
              // move under the name (see [_AdaptiveRow]).
              child: _AdaptiveRow(
                gap: AppSpacing.sm,
                minBodyWidth: _minNameColumnWidth,
                lead: Padding(
                  padding: const EdgeInsetsDirectional.only(end: AppSpacing.md),
                  child: ExcludeSemantics(
                    child: AppAvatar(url: user.avatarUrl, radius: avatarRadius),
                  ),
                ),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A hint from the server: false draws nothing and
                    // never means "public". The name ellipsizes first so the lock
                    // stays; the row wraps the control before the column is too
                    // narrow for the lock.
                    LayoutBuilder(
                      builder: (context, box) {
                        final badge =
                            user.isPrivate &&
                            box.maxWidth >= _badgeMinColumnWidth;
                        return Row(
                          children: [
                            Flexible(
                              child: Text(
                                user.displayName.isEmpty
                                    ? '@${user.handle}'
                                    : user.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            if (badge) ...[
                              const SizedBox(width: AppSpacing.xs),
                              const ProtectedBadge(),
                            ],
                          ],
                        );
                      },
                    ),
                    Text(
                      '@${user.handle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                          .merge(handleStyle),
                    ),
                  ],
                ),
                // A caller's own [trailing] follows the same rule: it is measured
                // at its natural width like the default control.
                actions: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (extraAction == null)
                      control
                    else
                      Flexible(
                        child: Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [control, extraAction!],
                        ),
                      ),
                    if (onDismiss != null)
                      IconButton(
                        tooltip: 'Dismiss @${user.handle}',
                        constraints: const BoxConstraints.tightFor(
                          width: AppSpacing.minTapTarget,
                          height: AppSpacing.minTapTarget,
                        ),
                        icon: Icon(
                          Icons.close,
                          size: AppIconSize.md,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        onPressed: onDismiss,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showDivider) const Divider(height: 1),
      ],
    );
  }
}

/// The narrowest name column (dp) that still gets the lock: the 16dp badge,
/// its 4dp gap and a little of the name.
const double _badgeMinColumnWidth = 48;

/// The narrowest name column (dp) the row accepts beside the control; under
/// it the control moves onto its own line under the name. Equal to the lock's
/// minimum so a protected name always keeps its badge while it is inline.
const double _minNameColumnWidth = _badgeMinColumnWidth;

/// avatar + name column + actions. Inline when the actions fit at their
/// natural width with at least [minBodyWidth] left for the name column;
/// otherwise the actions sit on their own line under the name column, aligned
/// to its start. Decided from measured widths, never from a text scale.
class _AdaptiveRow extends MultiChildRenderObjectWidget {
  _AdaptiveRow({
    required Widget lead,
    required Widget body,
    required Widget actions,
    required this.gap,
    required this.minBodyWidth,
  }) : super(children: [lead, body, actions]);

  final double gap;
  final double minBodyWidth;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAdaptiveRow(
    gap: gap,
    minBodyWidth: minBodyWidth,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAdaptiveRow renderObject,
  ) {
    renderObject
      ..gap = gap
      ..minBodyWidth = minBodyWidth
      ..textDirection = Directionality.of(context);
  }
}

class _RenderAdaptiveRow extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderAdaptiveRow({
    required double gap,
    required double minBodyWidth,
    required TextDirection textDirection,
  }) : _gap = gap,
       _minBodyWidth = minBodyWidth,
       _textDirection = textDirection;

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _minBodyWidth;
  set minBodyWidth(double v) {
    if (v == _minBodyWidth) return;
    _minBodyWidth = v;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = MultiChildLayoutParentData();
    }
  }

  @override
  void performLayout() {
    final lead = firstChild!;
    final body = childAfter(lead)!;
    final actions = childAfter(body)!;
    final width = constraints.maxWidth;

    lead.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    actions.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final free = width - lead.size.width - _gap - actions.size.width;
    final wrapped = free < _minBodyWidth;
    final bodyWidth = wrapped ? width - lead.size.width : free;
    body.layout(
      BoxConstraints(minWidth: bodyWidth, maxWidth: bodyWidth),
      parentUsesSize: true,
    );

    final double height;
    final double leadY, bodyY, actionsY, actionsX;
    if (wrapped) {
      height = math.max(
        lead.size.height,
        body.size.height + actions.size.height,
      );
      leadY = 0;
      bodyY = 0;
      actionsY = body.size.height;
      // Aligned to the text column; a control wider than that column (the
      // outlined Following at the largest text scale) starts further left
      // rather than leave the row.
      actionsX = math.min(
        lead.size.width,
        math.max(0, width - actions.size.width),
      );
    } else {
      height = math.max(
        lead.size.height,
        math.max(body.size.height, actions.size.height),
      );
      leadY = (height - lead.size.height) / 2;
      bodyY = (height - body.size.height) / 2;
      actionsY = (height - actions.size.height) / 2;
      actionsX = width - actions.size.width;
    }
    size = constraints.constrain(Size(width, height));

    double dx(double x, double w) =>
        _textDirection == TextDirection.rtl ? width - x - w : x;
    (lead.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
      dx(0, lead.size.width),
      leadY,
    );
    (body.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
      dx(lead.size.width, bodyWidth),
      bodyY,
    );
    (actions.parentData! as ContainerBoxParentData<RenderBox>).offset = Offset(
      dx(actionsX, actions.size.width),
      actionsY,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
