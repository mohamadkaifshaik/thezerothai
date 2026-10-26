import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/share/native_share.dart';
import '../../core/theme/app_theme.dart';
import 'app_menu_item_row.dart';
import 'sheet_option_row.dart';

/// What the user picked in the share menu.
enum PostShareChoice { copyLink, shareVia }

/// The 48dp square at the trailing edge of the render box of [context]: where
/// the Share button sits at the end of the post action row. It places the
/// anchored menu and the iPad / macOS share popover.
Rect trailingTargetRect(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Rect.zero;
  final origin = box.localToGlobal(Offset.zero);
  const side = AppSpacing.minTapTarget;
  final rtl = Directionality.of(context) == TextDirection.rtl;
  final left = rtl ? origin.dx : origin.dx + box.size.width - side;
  return Rect.fromLTWH(left, origin.dy, side, box.size.height);
}

/// The menu behind a post's Share button (X-style, W2-8): "Copy link" and,
/// where the device has a native share sheet ([NativeShare.isAvailable]),
/// "Share via...". Under [AppBreakpoints.mobile] it is a bottom sheet with a
/// title; from 600dp up it is a menu anchored at [anchor] (the Share button).
///
/// Everything is local: no RPC, no stream. The only thing that leaves the
/// device is [url], by the user's choice. "Copy link" writes exactly [url]
/// to the clipboard and answers with the toast "Copied to clipboard"; if the
/// clipboard refuses (some browsers) the toast says so instead, never
/// "Copied". A failing native sheet gets a toast too.
Future<void> showPostShareMenu(
  BuildContext context, {
  required String url,
  required NativeShare nativeShare,
  required Rect anchor,
}) async {
  // Everything the context is needed for is read before the first await: the
  // card under it may be gone by the time the user picks a row.
  final messenger = ScaffoldMessenger.of(context);
  final canShareVia = nativeShare.isAvailable;
  final wide = MediaQuery.sizeOf(context).width >= AppBreakpoints.mobile;
  final choice = wide
      ? await _showAnchoredMenu(context, anchor, canShareVia: canShareVia)
      : await _showSheet(context, canShareVia: canShareVia);
  if (choice == null) return;
  switch (choice) {
    case PostShareChoice.copyLink:
      try {
        await Clipboard.setData(ClipboardData(text: url));
      } catch (_) {
        _toast(messenger, "Couldn't copy the link. Try again.");
        return;
      }
      _toast(messenger, 'Copied to clipboard');
    case PostShareChoice.shareVia:
      try {
        await nativeShare.shareUrl(url, anchor: anchor);
      } catch (_) {
        _toast(messenger, "Couldn't open the share sheet. Try again.");
      }
  }
}

void _toast(ScaffoldMessengerState messenger, String text) => messenger
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

Future<PostShareChoice?> _showSheet(
  BuildContext context, {
  required bool canShareVia,
}) {
  return showModalBottomSheet<PostShareChoice>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Semantics(
              header: true,
              child: Text(
                'Share post',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          SheetOptionRow(
            icon: Icons.link,
            label: 'Copy link',
            onTap: () => Navigator.of(context).pop(PostShareChoice.copyLink),
          ),
          if (canShareVia)
            SheetOptionRow(
              icon: Icons.ios_share,
              label: 'Share via...',
              onTap: () => Navigator.of(context).pop(PostShareChoice.shareVia),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}

Future<PostShareChoice?> _showAnchoredMenu(
  BuildContext context,
  Rect anchor, {
  required bool canShareVia,
}) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<PostShareChoice>(
    context: context,
    position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
    semanticLabel: 'Share post',
    items: [
      const PopupMenuItem(
        value: PostShareChoice.copyLink,
        child: AppMenuItemRow(icon: Icons.link, label: 'Copy link'),
      ),
      if (canShareVia)
        const PopupMenuItem(
          value: PostShareChoice.shareVia,
          child: AppMenuItemRow(icon: Icons.ios_share, label: 'Share via...'),
        ),
    ],
  );
}
