import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/messages/domain/messages_list_detail.dart';
import '../../features/messages/presentation/thread_route_page.dart';
import '../widgets/tablet_layout.dart';
import '../widgets/tablet_modal.dart';

/// Whether the page right under the root page with [pageKey] draws the
/// tablet rail: a shell page (`ShellRouteMatch`), or the Messages split page
/// (a root thread route at 840-1199 dp, which draws `MainShell` itself). A
/// full-screen root page (Drafts, the photo viewer, a thread below 840 dp)
/// has no rail, and nor has a page with nothing under it (a cold start): a
/// modal page over it centres on the window (T2 ruling 2).
bool pageBelowDrawsRail(BuildContext context, LocalKey pageKey) {
  final router = GoRouter.maybeOf(context);
  if (router == null) return false;
  final matches = router.routerDelegate.currentConfiguration.matches;
  final index = matches.indexWhere((m) => m.pageKey == pageKey);
  if (index <= 0) return false;
  final below = matches[index - 1];
  if (below is ShellRouteMatch) return true;
  return isMessagesThreadLocation(below.matchedLocation) &&
      messagesSplitPageAt(context);
}

/// The tablet presentation of a dialog that is a page of its own on the
/// root navigator (`/premium`, `/messages/new`; tablet plan sections 4.1 and
/// 5.4), for a [context] inside its route: centred on the content area
/// beside the rail when the page under it draws one ([pageBelowDrawsRail]),
/// on the window otherwise. Null outside the tablet layout (phones, desktop,
/// either flag off), where the page keeps today's presentation.
TabletModalHost? dialogPageHost(BuildContext context) {
  if (!tabletLayoutAt(context)) return null;
  final settings = ModalRoute.of(context)?.settings;
  final key = settings is Page ? settings.key : null;
  return TabletModalHost(
    overShell: key is LocalKey && pageBelowDrawsRail(context, key),
  );
}

/// The frame of a dialog page's content ([dialogPageHost]): the safe area
/// today's `DialogRoute` adds, except on the tablet layout, where the
/// [TabletModalHost.dialogInsets] already keep the dialog inside it (both
/// would count the status bar and a landscape notch twice). The same
/// widgets in every case, so a resize only changes values. Its route sets
/// `useSafeArea: false`.
class DialogPageFrame extends StatelessWidget {
  const DialogPageFrame({super.key, required this.builder});

  /// Builds the dialog with the host ([dialogPageHost]; null: today's).
  final Widget Function(BuildContext context, TabletModalHost? host) builder;

  @override
  Widget build(BuildContext context) {
    final host = dialogPageHost(context);
    final safe = host == null;
    return SafeArea(
      left: safe,
      top: safe,
      right: safe,
      bottom: safe,
      child: Builder(builder: (context) => builder(context, host)),
    );
  }
}
