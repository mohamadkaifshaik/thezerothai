import 'package:flutter/widgets.dart';

/// Closes whatever is open above the page of [context] (dialogs, sheets,
/// menus and pages pushed over it), so the next pop leaves that page itself,
/// not something on top of it.
///
/// For root-level pages only (`/compose`, `/compose/reply/:id`: full-screen
/// routes outside the shell): there the page's navigator is the root one, so
/// a dialog shown from it is on that same navigator. A page inside a nested
/// navigator would also need the root navigator's popups closed.
///
/// Returns whether the page is still in the navigator and not already
/// leaving. When it is not (a redirect replaced the stack, or it is being
/// popped), nothing is touched and the caller must not pop either: that pop
/// would take another page.
bool closeRoutesAbove(BuildContext context) {
  final page = ModalRoute.of(context);
  if (page == null || !page.isActive) return false;
  if (!page.isCurrent) Navigator.of(context).popUntil((route) => route == page);
  return true;
}
