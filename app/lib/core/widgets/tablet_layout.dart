import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart' show ProviderNotFoundException;

import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import 'shell_geometry.dart';

/// Both flags of the tablet layout are on (`ui_shell` and `ui_tablet`,
/// tablet plan section 2.3). False without an `OnboardingBloc` above
/// [context] (a widget test without onboarding: no tablet layout).
///
/// [listen] subscribes [context] to the flags (a build); off, it reads them
/// once (a route's transition, an event handler).
bool tabletFlagsOn(BuildContext context, {bool listen = true}) {
  try {
    return listen
        ? isFeatureEnabled(context, kFeatureUiShell) &&
              isFeatureEnabled(context, kFeatureUiTablet)
        : featureEnabledSnapshot(context, kFeatureUiShell) &&
              featureEnabledSnapshot(context, kFeatureUiTablet);
  } on ProviderNotFoundException {
    return false;
  }
}

/// The tablet layout is in effect for the window of [context] now: both
/// flags ([tabletFlagsOn]) and a window 600-1199 dp wide. Pages outside the
/// shell (the composer, the photo viewer, the article editor) take their
/// tablet presentation from it; phones, desktop (ruling R-1) and either flag
/// off keep today's.
bool tabletLayoutAt(BuildContext context, {bool listen = true}) =>
    ShellBand.of(MediaQuery.sizeOf(context).width).isTablet &&
    tabletFlagsOn(context, listen: listen);
