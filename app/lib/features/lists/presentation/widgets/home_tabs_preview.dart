import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/context_pane.dart';
import '../../../../shared/widgets/primitives/app_tab_bar.dart';

/// The title of the Home tabs preview on Manage pinned.
const kHomeTabsPreviewTitle = 'Preview';

/// The line under the title.
const kHomeTabsPreviewCaption = 'Your Home tabs, in this order.';

/// The space around the preview's tab bar inside its card (the placeholder's
/// empty bar uses the same, so nothing moves when the page lends the card).
const kHomeTabsPreviewBarInset = EdgeInsets.fromLTRB(
  AppSpacing.sm,
  0,
  AppSpacing.sm,
  AppSpacing.sm,
);

/// [HomeTabsPreviewCard] until Manage pinned has lent it: the same card with
/// an empty bar of the same height, so the pane never opens on the footer
/// alone and nothing jumps when the tabs arrive.
class HomeTabsPreviewPlaceholder extends StatelessWidget {
  const HomeTabsPreviewPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => ContextPaneCard(
    title: kHomeTabsPreviewTitle,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Caption(),
        Padding(
          padding: kHomeTabsPreviewBarInset,
          child: SizedBox(height: AppTabBar.heightFor(context)),
        ),
      ],
    ),
  );
}

/// The Home tab bar as Manage pinned will leave it (tablet plan section 4.1,
/// ManagePinned: "preview of Home tabs", inline at the top in band A, beside
/// the editor in band B; T8b): Following first and selected, then [labels]
/// in order, drawn by the same [AppTabBar] as Home so the
/// weights and the indicator match.
///
/// It is a picture, not a control: it takes no pointer or focus and is
/// spoken as one line ("Home tabs preview: Following, …"). It shows only the
/// tabs the client has; the location project's "Nearby" tab is not among
/// them.
class HomeTabsPreviewCard extends StatelessWidget {
  const HomeTabsPreviewCard({
    super.key,
    required this.labels,
    this.margin = const EdgeInsets.only(bottom: AppSpacing.md),
  });

  /// The pinned tabs' labels after Following, in order.
  final List<String> labels;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final tabs = ['Following', ...labels];
    return ContextPaneCard(
      title: kHomeTabsPreviewTitle,
      margin: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Caption(),
          // Inset from the card's border and rounded corners, so the bar's
          // hairline and indicator stay inside the card.
          Padding(
            padding: kHomeTabsPreviewBarInset,
            child: Semantics(
              label: 'Home tabs preview: ${tabs.join(', ')}',
              excludeSemantics: true,
              child: ExcludeFocus(
                child: IgnorePointer(
                  child: AppTabBar(
                    selectedIndex: 0,
                    onChanged: (_) {},
                    tabs: [for (final t in tabs) AppTab(label: t)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        kHomeTabsPreviewCaption,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
