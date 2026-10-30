import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Opens the search page, optionally with [query] filled in (a trend row opens
/// `#tag`). The one place W4-17/18 build that location; W4-15 owns the
/// `/search` route and `AppRouter.searchPath(query, tab)`, and this function
/// is swapped for that helper once it is on main (the plan's seam: widgets
/// never string-build a path).
void openSearch(BuildContext context, {String? query}) {
  final q = query == null || query.isEmpty
      ? ''
      : '?q=${Uri.encodeQueryComponent(query)}';
  context.push('/search$q');
}
