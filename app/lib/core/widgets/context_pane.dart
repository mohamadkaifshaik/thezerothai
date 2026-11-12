import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shared/widgets/primitives/app_surface.dart';
import '../theme/app_theme.dart';

/// What a [ContextSection] shows. A page that also draws one of these
/// inline (Explore's and Home's "Who to follow") asks [ContextPaneScope]
/// whether the pane already shows it, so one widget has one placement at a
/// time (tablet plan section 5.1, "one widget, two placements").
///
/// Later tablet phases add their own kinds (T5 "Your plans", T8 the
/// per-feature cards).
enum ContextSectionKind {
  /// The global search pill.
  search,

  /// The signed-in user's card.
  profile,

  /// "What's happening": the top trends.
  trends,

  /// "Who to follow" / "You might like": the shared suggestions.
  whoToFollow,

  /// The footer links (Privacy Policy, Community rules).
  links,

  /// `/profile/:handle`, `/u/:id`: the profile's latest images from its
  /// own Media tab feed (T8c). The Media tab keeps them at every width.
  profileMedia,

  /// `/lists/:id`: a preview of the List's members with "Manage members" /
  /// "See all members" (T8b). The header keeps the count at every width.
  listMembers,

  /// `/home/pinned`: a preview of the Home tabs as they will show (T8b).
  homeTabsPreview,

  /// `/u/:id/lists`: the card of the Lists' owner (T8b).
  listsOwner,

  /// `/plans/new`, `/plans/:id/edit`: the live preview of the form (T8d).
  planPreview,

  /// `/plans/new`, `/plans/:id/edit`: "Tips for a good plan" (T8d).
  planTips,

}

/// One section of band B's context pane: a self-gating widget (it draws
/// nothing when its flags are off or it has nothing to show) that owns its
/// bottom gap, so an empty section leaves no space.
@immutable
class ContextSection {
  const ContextSection(this.kind, this.child);

  final ContextSectionKind kind;
  final Widget child;
}

/// Band B's context pane (tablet plan section 3, code P): the [sections] top
/// to bottom in one scroll view. Presentational: each section reads its own
/// data and flags.
///
/// The pane has no header, so it pads its scroll content by the top and
/// bottom safe-area insets itself; the shell has already taken the side
/// insets. Its scroll offset is not kept across a resize (plan section 5.2).
class ContextPane extends StatelessWidget {
  const ContextPane({super.key, required this.sections});

  final List<ContextSection> sections;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    return SingleChildScrollView(
      primary: false,
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        insets.top + AppSpacing.md,
        AppSpacing.md,
        insets.bottom + AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in sections)
            KeyedSubtree(key: ValueKey(section.kind), child: section.child),
        ],
      ),
    );
  }
}

/// One titled card of the context pane: an outlined `AppSurface` with a
/// bold [title] (a heading) over [child], as the "What's happening" card.
/// The card owns its bottom gap ([margin]).
class ContextPaneCard extends StatelessWidget {
  const ContextPaneCard({
    super.key,
    required this.title,
    required this.child,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
    this.titleTrailing,
    this.titleSemanticsLabel,
  });

  final String title;
  final Widget child;
  final EdgeInsetsGeometry margin;

  /// Drawn after the title on its line (a count badge); nothing when null.
  final Widget? titleTrailing;

  /// What the heading says instead of [title] (the title with its count).
  final String? titleSemanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSurface(
      margin: margin,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Semantics(
              header: true,
              label: titleSemanticsLabel,
              excludeSemantics: titleSemanticsLabel != null,
              child: _titleRow(theme),
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _titleRow(ThemeData theme) {
    final text = Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    final trailing = titleTrailing;
    if (trailing == null) return text;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [text, trailing],
    );
  }
}

/// Publishes which [ContextSectionKind]s the context pane beside the primary
/// pane shows. Present only on the tablet layout (`ResponsiveScaffold`
/// publishes it, with an empty set in band A and on pages without a pane);
/// absent everywhere else, where [shows] is false and pages keep their
/// inline sections exactly as before.
class ContextPaneScope extends InheritedWidget {
  const ContextPaneScope({
    super.key,
    required this.shown,
    required super.child,
  });

  final Set<ContextSectionKind> shown;

  /// Whether the context pane next to [context] shows [kind] (so an inline
  /// copy of it should not be drawn).
  static bool shows(BuildContext context, ContextSectionKind kind) =>
      context
          .dependOnInheritedWidgetOfExactType<ContextPaneScope>()
          ?.shown
          .contains(kind) ??
      false;

  @override
  bool updateShouldNotify(ContextPaneScope oldWidget) =>
      !setEquals(shown, oldWidget.shown);
}
