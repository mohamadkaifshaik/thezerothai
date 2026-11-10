import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router/app_router.dart';
import '../feature_flags/feature_flags.dart';
import '../../features/posts/domain/posts_feature_flag.dart';

import '../router/shell_entries.dart';
import '../../shared/widgets/primitives/app_menu_item_row.dart';

/// A rail destination folded into the More menu (the tablet rail at a short
/// height, `AppNavRail` R2/R3): its glyph and label, and what a tap does
/// (the same as tapping it on the rail).
class AppMoreMenuFoldedRow {
  const AppMoreMenuFoldedRow({
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// The menu behind the rail's "More" item (600 dp and up): the [entries] as
/// `AppMenuItemRow`s in a popup anchored at the More icon. Choosing one opens
/// it through [onSelected] (by default [openShellEntry]: `go`, or `push` for
/// the Premium dialog). Later waves add rows by extending the entry list.
/// 0 RPCs; the menu keeps the focus rules of `showMenu` (Escape and a tap
/// outside close it, focus returns to the More item).
abstract final class AppMoreMenu {
  /// The semantics of the menu itself.
  static const semanticLabel = 'More';

  /// Opens the menu anchored at [anchor] (a context at the More icon).
  /// [folded] destinations (the tablet rail at a short height) are listed
  /// first, above Articles and the [entries].
  static Future<void> show(
    BuildContext anchor, {
    required List<ShellEntry> entries,
    void Function(BuildContext context, ShellEntry entry)? onSelected,
    List<AppMoreMenuFoldedRow> folded = const [],
  }) async {
    final articles = featureEnabledSnapshot(anchor, kFeaturePosts);
    if (entries.isEmpty && !articles && folded.isEmpty) return;
    final box = anchor.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    // The menu opens to the right of the rail, its top edge level with the
    // item, like X's desktop More menu.
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(rect.right, rect.top, 0, rect.height),
      Offset.zero & overlay.size,
    );
    final chosen = await showMenu<Object>(
      context: anchor,
      position: position,
      semanticLabel: semanticLabel,
      items: [
        for (final row in folded)
          PopupMenuItem<Object>(
            value: row,
            child: AppMenuItemRow(icon: row.icon, label: row.label),
          ),
        if (articles)
          const PopupMenuItem<Object>(
            value: 'articles',
            child: AppMenuItemRow(
              icon: Icons.article_outlined,
              label: 'Articles',
            ),
          ),
        for (final entry in entries)
          PopupMenuItem<ShellEntry>(
            value: entry,
            child: AppMenuItemRow(icon: entry.icon, label: entry.label),
          ),
      ],
    );
    if (chosen == null || !anchor.mounted) return;
    if (chosen is AppMoreMenuFoldedRow) {
      chosen.onSelected();
    } else if (chosen == 'articles') {
      anchor.go(AppRouter.articlesPath);
    } else if (chosen is ShellEntry) {
      (onSelected ?? openShellEntry)(anchor, chosen);
    }
  }
}
