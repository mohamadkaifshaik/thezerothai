import 'package:flutter/widgets.dart';

/// Closes whatever is open above the page of [context]: dialogs, sheets and
/// menus (also those shown on the root navigator) and pages pushed over it.
/// The next pop then leaves that page itself, not something on top of it.
///
/// Does nothing for a page that is already leaving (or has no route): a
/// `popUntil` that never meets its page would empty the navigator.
void closeRoutesAbove(BuildContext context) {
  final page = ModalRoute.of(context);
  if (page == null || !page.isActive) return;
  final own = Navigator.of(context);
  final root = Navigator.of(context, rootNavigator: true);
  // A dialog or sheet on the root navigator sits above every nested page.
  if (!identical(root, own)) root.popUntil((route) => route is! PopupRoute);
  if (!page.isCurrent) own.popUntil((route) => route == page);
}
