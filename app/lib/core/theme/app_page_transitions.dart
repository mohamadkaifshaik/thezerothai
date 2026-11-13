import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The app's page transition: the new page fades in while it slides a little
/// (4% of its width) from the reading-direction end, ease-out, in 240 ms
/// ([AppMotion.pageTransition]). The page underneath stays put.
///
/// Under reduced motion (`MediaQuery.disableAnimations`) the page is shown
/// as it is: no fade, no slide.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.pageTransition;

  @override
  Duration get reverseTransitionDuration => AppMotion.pageTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.pageCurve,
      reverseCurve: AppMotion.pageCurve.flipped,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(AppMotion.pageSlide, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Every platform gets [AppPageTransitionsBuilder], except iOS and macOS:
/// they keep the Cupertino slide because it carries the edge swipe back.
const PageTransitionsTheme appPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: AppPageTransitionsBuilder(),
    TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
    TargetPlatform.linux: AppPageTransitionsBuilder(),
    TargetPlatform.windows: AppPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
  },
);
