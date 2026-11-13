import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/feature_flags/feature_flags.dart';
import '../../../core/feature_flags/ui_shell_feature_flag.dart';
import '../../../core/router/main_shell.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../auth/presentation/widgets/auth_gate.dart';
import 'bloc/conversations_session.dart';

/// Whether the root thread routes (`/messages/:id`, `/messages/new/draft`)
/// draw the Messages split page now (tablet plan section 5.3): the tablet
/// layout (`ui_shell` + `ui_tablet`) in band B (840-1199dp), with the app's
/// hoisted [ConversationsSession]. From 1200dp (desktop) the thread is inside
/// the shell too, without a list (the Chat mock has the peer's side column
/// instead: `ThreadSideBoxes`). Phones, band A and either flag off keep
/// today's full-screen thread.
///
/// [listen] subscribes [context] to the flags (a build); off, it reads them
/// once (a route's transition and duration).
bool messagesSplitPageAt(BuildContext context, {bool listen = true}) {
  final width = MediaQuery.sizeOf(context).width;
  final band = ShellBand.of(width);
  if (band != ShellBand.expanded && band != ShellBand.desktop) return false;
  try {
    final flags = listen
        ? isFeatureEnabled(context, kFeatureUiShell) &&
              isFeatureEnabled(context, kFeatureUiTablet)
        : featureEnabledSnapshot(context, kFeatureUiShell) &&
              featureEnabledSnapshot(context, kFeatureUiTablet);
    return flags && context.read<ConversationsSession?>() != null;
  } on ProviderNotFoundException {
    // No flags in scope (a widget test without onboarding): no tablet.
    return false;
  }
}

/// The page of the root thread routes, the same type at every width so that
/// a resize across 840dp updates the route instead of replacing it
/// (`Page.canUpdate` compares the type and the key; tablet plan section
/// 5.3, step 4).
///
/// Its route is the `MaterialPage` route (`MaterialRouteTransitionMixin`),
/// so below 840dp and on desktop the transition, its duration, the page
/// underneath's parallax and the iOS back swipe are exactly today's. On the
/// split page (840-1199dp, [messagesSplitPageAt]) the width decision inside
/// the route turns the transition off: no slide and no delay, so pushing a
/// thread from the shell inbox, or switching conversations inside the split
/// page, only changes the detail.
class ThreadPage<T> extends Page<T> {
  const ThreadPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => _ThreadPageRoute<T>(this);
}

class _ThreadPageRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  _ThreadPageRoute(ThreadPage<T> page) : super(settings: page);

  ThreadPage<T> get _page => settings as ThreadPage<T>;

  bool get _split {
    final context = navigator?.context;
    return context != null && messagesSplitPageAt(context, listen: false);
  }

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  // Read when the route is pushed and when it is popped
  // (`MaterialRouteTransitionMixin.didPush` / `didPop`).
  @override
  Duration get transitionDuration =>
      _split ? Duration.zero : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _split ? Duration.zero : super.reverseTransitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (messagesSplitPageAt(context, listen: false)) return child;
    return super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}

/// The child of the root thread routes (tablet plan section 5.2, "Thread
/// across 839↔840"): today's thread below 840dp, the Messages split page at
/// 840-1199dp (`MainShell` with the conversation list beside the thread) and
/// the thread inside the desktop shell from 1200dp.
///
/// It owns one `GlobalKey` and puts it on the [thread] in both branches, so a
/// resize across 840dp re-parents the thread (its cubits, scroll position,
/// composer text) instead of rebuilding it. [location] is the route's path
/// (the rail selects Messages, the list selects the conversation); [folder]
/// is the list beside it: Requests when the thread was opened from the
/// Requests folder, else the inbox. The `AuthGate` stays the route's
/// outermost widget, as before.
class ThreadRoutePage extends StatefulWidget {
  const ThreadRoutePage({
    super.key,
    required this.location,
    required this.folder,
    required this.thread,
  });

  final String location;
  final Folder folder;
  final Widget thread;

  @override
  State<ThreadRoutePage> createState() => _ThreadRoutePageState();
}

class _ThreadRoutePageState extends State<ThreadRoutePage> {
  final GlobalKey _threadKey = GlobalKey(debugLabel: 'thread-route-page');

  @override
  Widget build(BuildContext context) {
    final thread = KeyedSubtree(key: _threadKey, child: widget.thread);
    return AuthGate(
      child: messagesSplitPageAt(context)
          ? MainShell(
              location: widget.location,
              splitFolder: widget.folder,
              child: thread,
            )
          : thread,
    );
  }
}
