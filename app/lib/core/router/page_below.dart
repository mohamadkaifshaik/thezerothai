import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/messages/domain/messages_list_detail.dart';
import '../../features/messages/presentation/thread_route_page.dart';
import '../widgets/shell_geometry.dart';
import '../widgets/tablet_layout.dart';
import '../widgets/tablet_modal.dart';
import 'app_router.dart';

/// Whether the page right under the root page with [pageKey] draws the
/// tablet rail: a shell page (`ShellRouteMatch`), or the Messages split page
/// (a root thread route at 840-1199 dp, which draws `MainShell` itself). A
/// full-screen root page (Drafts, the photo viewer, a thread below 840 dp)
/// has no rail, and nor has a page with nothing under it (a cold start): a
/// modal page over it centres on the window (T2 ruling 2).
bool pageBelowDrawsRail(BuildContext context, LocalKey pageKey) =>
    _pageBelow(context, pageKey) != null;

/// The location of the shell page that draws the rail under the root page
/// with [pageKey] ([pageBelowDrawsRail]), or null when there is none.
String? _pageBelow(BuildContext context, LocalKey pageKey) {
  final router = GoRouter.maybeOf(context);
  if (router == null) return null;
  final matches = router.routerDelegate.currentConfiguration.matches;
  final index = matches.indexWhere((m) => m.pageKey == pageKey);
  if (index <= 0) return null;
  final below = matches[index - 1];
  if (below is ShellRouteMatch) return below.matchedLocation;
  return isMessagesThreadLocation(below.matchedLocation) &&
          messagesSplitPageAt(context)
      ? below.matchedLocation
      : null;
}

/// The shell location [location] is Settings, whose list sits beside the
/// page as the desktop shell's master pane (>= 1200 dp, in place of the
/// side column). `MainShell` and the dialog pages take the same decision
/// here, so a dialog page knows where the desktop column under it is.
bool isSettingsLocation(String location) =>
    location.startsWith(AppRouter.settingsPath);

/// The shell [location] is one of the pages the desktop shows in the
/// Settings master-detail (Creator Studio, Calls, Advertise): beside the
/// Settings categories from 1200 dp, a page of their own below that.
bool isSettingsSidePage(String location) =>
    location == AppRouter.creatorStudioPath ||
    location == AppRouter.callsPath ||
    location == AppRouter.advertisePath;

/// The presentation of a dialog that is a page of its own on the root
/// navigator (`/premium`, `/messages/new`; tablet plan sections 4.1 and
/// 5.4), for a [context] inside its route: centred on the content area
/// beside the rail when the page under it draws one ([pageBelowDrawsRail]),
/// on the window otherwise. From 1200 dp (D1) "the content area" is the
/// desktop shell's feed column, placed by the page under it (the Settings
/// master pane, or the side column). Null on phones and with either flag
/// off, where the page keeps today's presentation.
TabletModalHost? dialogPageHost(BuildContext context) {
  final band = ShellBand.of(MediaQuery.sizeOf(context).width);
  if (band == ShellBand.phone || !tabletFlagsOn(context)) return null;
  final settings = ModalRoute.of(context)?.settings;
  final key = settings is Page ? settings.key : null;
  final below = key is LocalKey ? _pageBelow(context, key) : null;
  return TabletModalHost(
    overShell: below != null,
    // The shell under the page publishes its live panes; until it has (a
    // first frame), the page under it says whether the master pane is shown.
    desktop:
        DesktopShellSlots.of(context) ??
        DesktopColumnSlots(
          master:
              below != null &&
              (isSettingsLocation(below) ||
                  (band == ShellBand.desktop && isSettingsSidePage(below))),
        ),
  );
}

/// The frame of a dialog page's content ([dialogPageHost]): the safe area
/// today's `DialogRoute` adds, except on the tablet and desktop layouts,
/// where the [TabletModalHost.dialogInsets] already keep the dialog inside
/// it (both would count the status bar and a landscape notch twice). The
/// same widgets in every case, so a resize only changes values. Its route
/// sets `useSafeArea: false`.
class DialogPageFrame extends StatefulWidget {
  const DialogPageFrame({super.key, required this.builder});

  /// Builds the dialog with the host ([dialogPageHost]; null: today's).
  final Widget Function(BuildContext context, TabletModalHost? host) builder;

  @override
  State<DialogPageFrame> createState() => _DialogPageFrameState();
}

class _DialogPageFrameState extends State<DialogPageFrame> {
  ValueNotifier<DesktopColumnSlots?>? _slots;

  // The desktop shell under the page changed its panes (a text scale that
  // widens the rail, Settings' master pane): the dialog is placed again.
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = DesktopShellSlots.notifierOf(context);
    if (next == _slots) return;
    _slots?.removeListener(_changed);
    next?.addListener(_changed);
    _slots = next;
  }

  @override
  void dispose() {
    _slots?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = dialogPageHost(context);
    final safe = host == null;
    return SafeArea(
      left: safe,
      top: safe,
      right: safe,
      bottom: safe,
      child: Builder(builder: (context) => widget.builder(context, host)),
    );
  }
}
