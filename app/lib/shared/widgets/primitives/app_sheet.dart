import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tablet_modal.dart';
import 'app_dialog.dart';

/// How [showAppSheet] presents its content.
enum AppSheetPresentation {
  /// A modal bottom sheet (phones).
  sheet,

  /// A menu anchored at the trigger (desktop).
  menu,
}

/// Which presentation to use for a window [width].
///
/// A caller opts in to the menu by passing the [menuFromWidth] it wants (for
/// example [AppBreakpoints.tablet]) and an anchor. The default
/// ([double.infinity]) never switches, so existing call sites keep their
/// sheet. Without an anchor the sheet is always used: a menu needs a place to
/// hang from.
AppSheetPresentation appSheetPresentationFor(
  double width, {
  double menuFromWidth = double.infinity,
  bool hasAnchor = true,
}) => hasAnchor && width >= menuFromWidth
    ? AppSheetPresentation.menu
    : AppSheetPresentation.sheet;

/// What a bottom sheet becomes on the tablet layout (`ui_shell` +
/// `ui_tablet`, 600-1199 dp), which has no bottom sheets (tablet plan
/// sections 4.2 and 5.4).
enum AppSheetOnTablet {
  /// A menu anchored at the trigger (pickers: repost, audience, reply
  /// audience). Needs an `anchor`; without one it is a [dialog].
  menu,

  /// A dialog centred on the content area, at most [AppSize.dialogMax] wide
  /// (forms and longer content: report, add to lists, join note,
  /// appearance, image description).
  dialog,
}

/// The arguments of a call site's own `showModalBottomSheet`, for
/// [showAppSheet]'s `material`: outside the tablet layout the sheet is
/// exactly `showModalBottomSheet` with these (and the builder, unchanged), so
/// phones, desktop and the 600-1199 dp layout with `ui_tablet` off keep
/// today's sheet (ruling R-1). The defaults are `showModalBottomSheet`'s.
@immutable
class MaterialSheetOptions {
  const MaterialSheetOptions({
    this.showDragHandle,
    this.isScrollControlled = false,
    this.useSafeArea = false,
    this.useRootNavigator = false,
    this.constraints,
  });

  final bool? showDragHandle;
  final bool isScrollControlled;
  final bool useSafeArea;
  final bool useRootNavigator;
  final BoxConstraints? constraints;
}

/// Shows [builder] as a bottom sheet, or (with [anchor] and [menuFromWidth])
/// as a menu anchored at the trigger once the window is wide enough. The same
/// content serves both, so a caller chooses by width and nothing else changes.
///
/// Sheet: top radius 32, a 36 x 4 drag handle inside a 48 dp target, scroll
/// controlled, in the safe area, at most [maxWidth] wide (640, as before), on
/// the root navigator. With [material] the sheet is instead the call site's
/// own `showModalBottomSheet` ([MaterialSheetOptions]).
///
/// Menu: [menuWidth] wide, hung below the anchor (above it when there is no
/// room), clamped to the window, scrolling when taller than the room. Arrow
/// keys move between its items.
///
/// Tablet layout (`ui_shell` + `ui_tablet`, 600-1199 dp): never a bottom
/// sheet. [onTablet] picks the anchored menu (with an [anchor]) or a dialog
/// centred on the content area, `min(tabletDialogMaxWidth, C - 48)` wide,
/// on the root navigator with the barrier over the whole window (the rail
/// is inert). The content keeps its own title. [tabletScrollable] scrolls
/// content that does not scroll itself. [host] is as for [showAppDialog].
/// The desktop layout (the same flags, >= 1200 dp) does the same: the menu
/// at the trigger, or the dialog centred on the shell's feed column (D1).
///
/// The content sits in a `Flexible` under the handle: content that can be
/// taller than the window (a long list) scrolls itself, with a shrink-wrapped
/// `ListView` for instance.
///
/// Focus (all): it moves into the content when nothing inside holds it,
/// Tab cycles inside, Escape and the system back close it, and focus returns
/// to whatever held it before. [semanticLabel] names the sheet or menu.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 640,
  String? semanticLabel,
  bool isDismissible = true,
  bool enableDrag = true,
  BuildContext? anchor,
  double menuFromWidth = double.infinity,
  double menuWidth = 320,
  MaterialSheetOptions? material,
  AppSheetOnTablet onTablet = AppSheetOnTablet.dialog,
  double tabletDialogMaxWidth = AppSize.dialogMax,
  bool tabletScrollable = false,
  TabletModalHost? host,
}) {
  host ??= TabletModalHost.of(context);
  if (host != null) {
    if (onTablet == AppSheetOnTablet.menu && anchor != null) {
      return _showAnchoredMenu<T>(
        context: context,
        anchor: anchor,
        builder: builder,
        width: menuWidth,
        semanticLabel: semanticLabel,
        isDismissible: isDismissible,
        host: host,
      );
    }
    return showAppDialog<T>(
      context: context,
      host: host,
      maxWidth: tabletDialogMaxWidth,
      barrierDismissible: isDismissible,
      builder: (dialogContext) => _TabletSheetContent(
        semanticLabel: semanticLabel,
        scrollable: tabletScrollable,
        child: builder(dialogContext),
      ),
    );
  }
  if (material != null) {
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: material.showDragHandle,
      isScrollControlled: material.isScrollControlled,
      useSafeArea: material.useSafeArea,
      useRootNavigator: material.useRootNavigator,
      constraints: material.constraints,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      builder: builder,
    );
  }
  final width = MediaQuery.sizeOf(context).width;
  final presentation = appSheetPresentationFor(
    width,
    menuFromWidth: menuFromWidth,
    hasAnchor: anchor != null,
  );
  if (presentation == AppSheetPresentation.menu) {
    return _showAnchoredMenu<T>(
      context: context,
      anchor: anchor!,
      builder: builder,
      width: menuWidth,
      semanticLabel: semanticLabel,
      isDismissible: isDismissible,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    // The theme's handle is 32 x 4; the design's is 36 x 4 in a 48 dp target.
    showDragHandle: false,
    constraints: BoxConstraints(maxWidth: maxWidth),
    builder: (sheetContext) => _FocusIntoContent(
      child: Semantics(
        scopesRoute: true,
        namesRoute: semanticLabel != null,
        explicitChildNodes: true,
        label: semanticLabel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppSheetHandle(),
            Flexible(child: builder(sheetContext)),
          ],
        ),
      ),
    ),
  );
}

Future<T?> _showAnchoredMenu<T>({
  required BuildContext context,
  required BuildContext anchor,
  required WidgetBuilder builder,
  required double width,
  required String? semanticLabel,
  required bool isDismissible,
  TabletModalHost? host,
}) {
  final box = anchor.findRenderObject() as RenderBox?;
  final rect = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.fromLTWH(MediaQuery.sizeOf(context).width / 2, 0, 0, 0);
  return showGeneralDialog<T>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: isDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
    pageBuilder: (menuContext, _, _) {
      final menu = CustomSingleChildLayout(
        delegate: _AnchoredMenuLayout(
          anchor: rect,
          width: width,
          padding: MediaQuery.paddingOf(menuContext),
          viewInsets: MediaQuery.viewInsetsOf(menuContext),
          textDirection: Directionality.of(menuContext),
        ),
        child: _AppMenuSurface(
          semanticLabel: semanticLabel,
          isDismissible: isDismissible,
          // The tablet menu shows content written for a sheet: the window's
          // safe area and keyboard are the layout's business, not the rows'.
          child: host == null
              ? builder(menuContext)
              : MediaQuery.removeViewInsets(
                  context: menuContext,
                  removeLeft: true,
                  removeTop: true,
                  removeRight: true,
                  removeBottom: true,
                  child: Builder(
                    builder: (context) => MediaQuery.removePadding(
                      context: context,
                      removeLeft: true,
                      removeTop: true,
                      removeRight: true,
                      removeBottom: true,
                      child: Builder(builder: builder),
                    ),
                  ),
                ),
        ),
      );
      return host == null ? menu : TabletModalScope(host: host, child: menu);
    },
  );
}

/// Sheet content shown in the tablet dialog: the drag handle's room becomes
/// top padding, the window's safe area is the dialog's (not the rows'), and
/// it is named like the sheet.
class _TabletSheetContent extends StatelessWidget {
  const _TabletSheetContent({
    required this.semanticLabel,
    required this.scrollable,
    required this.child,
  });

  final String? semanticLabel;
  final bool scrollable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: true,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
        child: child,
      ),
    );
    return _FocusIntoContent(
      child: Semantics(
        scopesRoute: true,
        namesRoute: semanticLabel != null,
        explicitChildNodes: true,
        label: semanticLabel,
        // The frame paints the surface above the dialog's own Material, so
        // the rows' ink needs one of its own.
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(child: content)
                    : content,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Positions the menu: below the anchor (above when there is no room), its
/// start edge on the anchor's, then clamped to the window.
class _AnchoredMenuLayout extends SingleChildLayoutDelegate {
  const _AnchoredMenuLayout({
    required this.anchor,
    required this.width,
    required this.padding,
    required this.viewInsets,
    required this.textDirection,
  });

  final Rect anchor;
  final double width;
  final EdgeInsets padding;
  final EdgeInsets viewInsets;
  final TextDirection textDirection;

  static const double _margin = AppSpacing.sm;

  Rect _room(Size size) => Rect.fromLTRB(
    padding.left + _margin,
    padding.top + _margin,
    size.width - padding.right - _margin,
    size.height - math.max(padding.bottom, viewInsets.bottom) - _margin,
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final room = _room(constraints.biggest);
    final below = room.bottom - anchor.bottom;
    final above = anchor.top - room.top;
    return BoxConstraints(
      minWidth: math.min(width, room.width),
      maxWidth: math.min(width, room.width),
      maxHeight: math.max(math.max(below, above), 0),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final room = _room(size);
    final below = room.bottom - anchor.bottom;
    final dy = childSize.height <= below
        ? anchor.bottom
        : anchor.top - childSize.height;
    final startX = textDirection == TextDirection.ltr
        ? anchor.left
        : anchor.right - childSize.width;
    return Offset(
      startX.clamp(
        room.left,
        math.max(room.left, room.right - childSize.width),
      ),
      dy.clamp(room.top, math.max(room.top, room.bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_AnchoredMenuLayout old) =>
      anchor != old.anchor ||
      width != old.width ||
      padding != old.padding ||
      viewInsets != old.viewInsets ||
      textDirection != old.textDirection;
}

class _AppMenuSurface extends StatelessWidget {
  const _AppMenuSurface({
    required this.semanticLabel,
    required this.isDismissible,
    required this.child,
  });

  final String? semanticLabel;
  final bool isDismissible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(AppRadius.menu);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (isDismissible) Navigator.of(context).maybePop();
              return null;
            },
          ),
        },
        child: Semantics(
          scopesRoute: true,
          namesRoute: semanticLabel != null,
          explicitChildNodes: true,
          role: SemanticsRole.menu,
          label: semanticLabel,
          child: _FocusIntoContent(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color:
                      theme.popupMenuTheme.color ?? theme.colorScheme.surface,
                  borderRadius: radius,
                  boxShadow: AppShadows.brand,
                  border: Border.all(color: theme.colorScheme.outline),
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: Material(
                    type: MaterialType.transparency,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.xs,
                      ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Moves focus to the first focusable item of the route once it is built,
/// unless something inside (a text field with `autofocus`, a confirm button)
/// already holds it. The route's own scope traps Tab and restores the previous
/// focus when it closes.
class _FocusIntoContent extends StatefulWidget {
  const _FocusIntoContent({required this.child});

  final Widget child;

  @override
  State<_FocusIntoContent> createState() => _FocusIntoContentState();
}

class _FocusIntoContentState extends State<_FocusIntoContent> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scope = FocusScope.of(context);
      final current = FocusManager.instance.primaryFocus;
      final inside =
          current != null &&
          current != scope &&
          current.ancestors.contains(scope);
      if (!inside) scope.nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The sheet's drag handle: a 36 x 4 pill in a full-width, 48 dp tall target.
/// Dragging the sheet works anywhere on it; tapping the handle (or its
/// "Close" action for a screen reader) closes the sheet.
class AppSheetHandle extends StatelessWidget {
  const AppSheetHandle({super.key});

  /// Size of the visible pill.
  static const Size pill = Size(36, 4);

  @override
  Widget build(BuildContext context) {
    final navigator = Navigator.of(context);
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).closeButtonLabel,
      onTap: navigator.maybePop,
      excludeSemantics: true,
      child: InkResponse(
        // Keyboard users close with Escape; focus belongs to the options.
        canRequestFocus: false,
        onTap: navigator.maybePop,
        radius: AppSpacing.lg,
        child: SizedBox(
          height: AppSpacing.minTapTarget,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.appColors.uiBorder,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: SizedBox.fromSize(size: pill),
            ),
          ),
        ),
      ),
    );
  }
}
