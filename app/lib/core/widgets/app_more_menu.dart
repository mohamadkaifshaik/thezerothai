import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router/app_router.dart';
import '../feature_flags/feature_flags.dart';
import '../../features/posts/domain/posts_feature_flag.dart';

import '../../features/shells/domain/shell_entries.dart';
import '../../shared/widgets/primitives/app_menu_item_row.dart';

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
  static Future<void> show(
    BuildContext anchor, {
    required List<ShellEntry> entries,
    void Function(BuildContext context, ShellEntry entry)? onSelected,
  }) async {
    final articles = featureEnabledSnapshot(anchor, kFeaturePosts);
    if (entries.isEmpty && !articles) return;
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
    if (chosen == 'articles') {
      anchor.go(AppRouter.articlesPath);
    } else if (chosen is ShellEntry) {
      (onSelected ?? openShellEntry)(anchor, chosen);
    }
  }
}
