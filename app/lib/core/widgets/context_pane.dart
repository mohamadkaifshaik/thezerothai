import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
