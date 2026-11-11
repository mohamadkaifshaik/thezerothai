import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/router/page_below.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';
import '../../../core/widgets/tablet_layout.dart';
import '../../../core/widgets/tablet_modal.dart';

/// How a composer route (`/compose`, `/compose/reply/:id`) draws its editor
/// now (tablet plan section 4.1, Composer and ReplyComposer rows; 5.4).
enum ComposerPresentation {
  /// The editor fills the window: phones, desktop for `/compose` (ruling
  /// R-1), every layout with a tablet flag off below the reply's
  /// [kLegacyReplyDialogFrom], and a cold start on the tablet layout.
  fullScreen,

  /// The tablet layout (`ui_shell` + `ui_tablet`, 600-1199 dp) with a page
  /// under the route: D 600, centred on the content area beside the rail
  /// (or on the window over a full-screen page), scrim over everything.
  tabletDialog,

  /// The reply route's dialog outside the tablet layout from
  /// [kLegacyReplyDialogFrom]: today's 600 x 85 % `Dialog`, unchanged
  /// (ruling R-1).
  legacyDialog,
}

/// The reply route's dialog threshold outside the tablet layout (today's
/// literal; on the tablet layout it is `AppBreakpoints.mobile`, F7).
const double kLegacyReplyDialogFrom = 700;

/// The presentation for a window [width] wide (a pure rule).
///
/// [tabletLayout]: both tablet flags are on. [hasPageBelow]: the route is
/// not the first page (the cold-start rule: a typed URL, a reload, a
/// restored history or a deep link has nothing under it, so it is full
/// screen even on the tablet layout). [reply]: the reply route, which keeps
/// its legacy dialog from 700 dp outside the tablet layout.
ComposerPresentation composerPresentationFor({
  required double width,
  required bool tabletLayout,
  required bool hasPageBelow,
  required bool reply,
}) {
  if (tabletLayout && ShellBand.of(width).isTablet) {
    return hasPageBelow
        ? ComposerPresentation.tabletDialog
        : ComposerPresentation.fullScreen;
  }
  if (reply && width >= kLegacyReplyDialogFrom) {
    return ComposerPresentation.legacyDialog;
  }
  return ComposerPresentation.fullScreen;
}

/// The page of `/compose`: the same type at every width, so a resize across
/// 600 or 1200 dp updates the route instead of replacing it
/// (`Page.canUpdate` compares the type and the key).
///
/// Its route is opaque while full screen (the page under it offstage, as
/// with today's `MaterialPage`) and not opaque while it is the tablet dialog
/// (the page under it painted behind the scrim). The plan (section 4.1)
/// made the page never opaque because "the page's opacity cannot change on
/// resize"; the route's overlay entry can, so a resize switches it and
/// phones and desktop keep an opaque page. Its transition is the
/// `MaterialPage` one
/// (`MaterialRouteTransitionMixin`: the platform's enter animation, its
/// duration and the iOS back swipe) when full screen, and a fade when it is
/// the dialog. The page underneath never runs its exit animation (no
/// parallax or zoom-out under the composer), so it is always at rest when a
/// rotation or resize turns the full-screen composer into the dialog.
class ComposerPage<T> extends Page<T> {
  const ComposerPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => _ComposerPageRoute<T>(this);
}

class _ComposerPageRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  _ComposerPageRoute(ComposerPage<T> page) : super(settings: page);

  ComposerPage<T> get _page => settings as ComposerPage<T>;

  /// The presentation is the tablet dialog: the route is then not opaque.
  bool _dialog = false;

  bool _dialogIn(BuildContext context) =>
      composerPresentationFor(
        width: MediaQuery.sizeOf(context).width,
        tabletLayout: tabletFlagsOn(context, listen: false),
        hasPageBelow: !isFirst,
        reply: false,
      ) ==
      ComposerPresentation.tabletDialog;

  @override
  void install() {
    final context = navigator?.context;
    _dialog = context != null && _dialogIn(context);
    super.install();
  }

  @override
  Widget buildContent(BuildContext context) => _page.child;

  /// Opaque while full screen, as `MaterialPage` (the page under it is
  /// offstage, as today); not opaque while it is the dialog, so the page
  /// under it shows behind the scrim. A resize that switches the
  /// presentation switches the overlay entry after the frame
  /// ([buildTransitions]).
  @override
  bool get opaque => !_dialog;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final dialog = _dialogIn(context);
    if (dialog != _dialog) {
      _dialog = dialog;
      // `TransitionRoute` sets the entry's opacity from [opaque] when the
      // transition completes; a resize after that needs it set again (not
      // during a build: the overlay rebuilds).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isActive && (animation.isCompleted) && overlayEntries.isNotEmpty) {
          overlayEntries.first.opaque = opaque;
        }
      });
    }
    if (dialog) return FadeTransition(opacity: animation, child: child);
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

/// The child of the composer routes: the [editor] full screen, in the
/// tablet dialog or (the reply only) in today's dialog, per
/// [composerPresentationFor].
///
/// It owns one `GlobalKey` and puts it on the [editor] in every branch
/// (tablet plan section 5.2, "Composer and reply editors"), so a resize or a
/// rotation across 600 or 1200 dp (or 700 for the legacy reply dialog)
/// re-parents the editor: its cubits, its text field and what was typed
/// survive. [pageKey] is the route's page key (`GoRouterState.pageKey`),
/// used to find the page under it.
class ComposerRouteFrame extends StatefulWidget {
  const ComposerRouteFrame({
    super.key,
    required this.pageKey,
    required this.reply,
    required this.semanticLabel,
    required this.editor,
    this.drawScrim = true,
  });

  final LocalKey pageKey;

  /// The reply route ([ComposerPresentation.legacyDialog] from 700 dp off the
  /// tablet layout).
  final bool reply;

  /// Names the tablet dialog ("New post", "Reply").
  final String semanticLabel;

  final Widget editor;

  /// The tablet dialog draws its own scrim. Off for a route that has a
  /// barrier of its own (the reply's `CustomTransitionPage`).
  final bool drawScrim;

  @override
  State<ComposerRouteFrame> createState() => _ComposerRouteFrameState();
}

class _ComposerRouteFrameState extends State<ComposerRouteFrame> {
  final GlobalKey _editorKey = GlobalKey(debugLabel: 'composer-editor');

  @override
  Widget build(BuildContext context) {
    final editor = KeyedSubtree(key: _editorKey, child: widget.editor);
    final presentation = composerPresentationFor(
      width: MediaQuery.sizeOf(context).width,
      tabletLayout: tabletFlagsOn(context),
      hasPageBelow: !(ModalRoute.of(context)?.isFirst ?? true),
      reply: widget.reply,
    );
    switch (presentation) {
      case ComposerPresentation.fullScreen:
        return editor;
      case ComposerPresentation.legacyDialog:
        return LayoutBuilder(
          builder: (context, constraints) => Dialog(
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: 600,
              height: constraints.maxHeight * .85,
              child: editor,
            ),
          ),
        );
      case ComposerPresentation.tabletDialog:
        return _TabletComposerDialog(
          host: TabletModalHost(
            overShell: composerOverRail(context, widget.pageKey),
          ),
          semanticLabel: widget.semanticLabel,
          drawScrim: widget.drawScrim,
          editor: editor,
        );
    }
  }
}

/// Whether the page right under the route with [pageKey] draws the tablet
/// rail ([pageBelowDrawsRail]): the dialog then centres on the content area
/// beside it; over a full-screen root page it centres on the window (T2
/// ruling 2).
bool composerOverRail(BuildContext context, LocalKey pageKey) =>
    pageBelowDrawsRail(context, pageKey);

/// The composer dialog of the tablet layout (code D 600): at most
/// `min(600, C - 48)` wide and `min(85 % of H, 720)` tall, within
/// `H - keyboard - 48`, centred on the content area of [host]. The scrim
/// covers the whole window, the rail included. Escape closes it the way
/// Close does (asking first when something was typed).
///
/// It sits in a transparent full-window `Scaffold`, so the editor's own
/// `Scaffold` is nested: a snack bar shown while it is open floats over the
/// scrim at the bottom of the same content area as the shell's (tablet plan
/// section 4.2), not inside the dialog.
class _TabletComposerDialog extends StatelessWidget {
  const _TabletComposerDialog({
    required this.host,
    required this.semanticLabel,
    required this.drawScrim,
    required this.editor,
  });

  final TabletModalHost host;
  final String semanticLabel;
  final bool drawScrim;
  final Widget editor;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = math.min(size.height * .85, AppSize.composerDialogMaxHeight);
    final insets = host.dialogInsets(context);
    return TabletModalScope(
      host: host,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: TabletSnackBarTheme(
          content: host.contentIn(context),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (drawScrim)
                  ModalBarrier(
                    color: context.appColors.scrim,
                    dismissible: false,
                  ),
                Semantics(
                  label: semanticLabel,
                  namesRoute: true,
                  scopesRoute: true,
                  explicitChildNodes: true,
                  child: Dialog(
                    insetPadding: insets,
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: AppSize.composerDialogMax,
                      height: height,
                      // The dialog is inside the safe area already: the
                      // editor's `SafeArea` and app bar add nothing more.
                      child: Builder(
                        builder: (inner) => MediaQuery.removePadding(
                          context: inner,
                          removeLeft: true,
                          removeTop: true,
                          removeRight: true,
                          removeBottom: true,
                          child: editor,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
