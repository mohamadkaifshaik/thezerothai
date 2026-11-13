import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/theme_mode_cubit.dart';
import '../../../../core/widgets/privacy_policy_link.dart';
import '../../../../shared/widgets/primitives/app_dialog.dart';
import '../../../../shared/widgets/primitives/app_rings.dart';
import 'email_password_form.dart';

/// The words of one auth mode. Phone, tablet and desktop show the same
/// copy, form and actions; only the arrangement differs.
@immutable
class AuthCopy {
  const AuthCopy._({
    required this.eyebrow,
    required this.headline,
    required this.accent,
    required this.heroHeadline,
    required this.heroAccent,
    required this.submitLabel,
    required this.switchPrompt,
    required this.switchAction,
  });

  final String eyebrow;

  /// The form headline: [headline] then [accent] in the accent colour, then
  /// a full stop.
  final String headline;
  final String accent;

  /// The desktop hero headline, built the same way.
  final String heroHeadline;
  final String heroAccent;

  final String submitLabel;
  final String switchPrompt;
  final String switchAction;

  static const heroBody =
      'Less scrolling. More connecting. Share what you want to do, and '
      'someone nearby wants that too.';

  static const signIn = AuthCopy._(
    eyebrow: 'Your people are here',
    headline: 'Good to see ',
    accent: 'you',
    heroHeadline: 'Your plans\ndeserve ',
    heroAccent: 'company',
    submitLabel: 'Log in',
    switchPrompt: 'New here?',
    switchAction: 'Sign up',
  );

  static const signUp = AuthCopy._(
    eyebrow: 'Good things start with a plan',
    headline: 'A plan starts ',
    accent: 'here',
    heroHeadline: 'Start something\n',
    heroAccent: 'nearby',
    submitLabel: 'Sign up',
    switchPrompt: 'Already have an account?',
    switchAction: 'Log in',
  );
}

/// Which of the three looks a width gets.
enum AuthLook {
  phone,
  tablet,
  desktop;

  static AuthLook of(double width) => width < AppBreakpoints.mobile
      ? phone
      : width < AppBreakpoints.tablet
      ? tablet
      : desktop;
}

/// Builds the screen's form for a look; the page passes how to arrange the
/// fields and the submit button.
typedef AuthFormFactory = Widget Function({
  required bool fieldIcons,
  required bool dense,
  required EmailPasswordFormBuilder builder,
});

/// Sign-in and sign-up page from the dzeroth-mobile, tablet and desktop
/// SignIn / SignUp mocks: a phone page with the actions pinned to the
/// bottom, a centred tablet column between the wordmark and footer, and the
/// desktop hero + form split.
class AuthPageLayout extends StatelessWidget {
  const AuthPageLayout({
    super.key,
    required this.copy,
    required this.signUp,
    required this.form,
    required this.social,
    required this.onSwitchMode,
    required this.onBack,
  });

  final AuthCopy copy;
  final bool signUp;
  final AuthFormFactory form;

  /// The provider buttons (Google, and Apple where available).
  final Widget social;

  /// Null while a request is in flight.
  final VoidCallback? onSwitchMode;

  /// "All sign-in options": back to Welcome. Null while a request is in
  /// flight.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        switch (AuthLook.of(constraints.maxWidth)) {
          AuthLook.phone => _phone(context),
          AuthLook.tablet => _tablet(context),
          AuthLook.desktop => _desktop(context, constraints.maxWidth),
        },
  );

  /// Everything under the submit button, in every look.
  Widget _after(
    BuildContext context, {
    required bool privacyLink,
    bool divider = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (divider)
        const AuthOrDivider()
      else
        const SizedBox(height: AppAuthLayout.actionsGap),
      social,
      const SizedBox(height: AppSpacing.sm),
      AuthSwitchLine(
        prompt: copy.switchPrompt,
        action: copy.switchAction,
        onPressed: onSwitchMode,
      ),
      if (signUp)
        const PrivacyPolicyLink(
          leadingText:
              "By signing up you confirm you're 18 or older and agree to our ",
        )
      else if (privacyLink)
        const Center(child: PrivacyPolicyLink()),
    ],
  );

  Widget _formHeader(
    BuildContext context,
    double size, {
    double fieldsTop = AppAuthLayout.fieldsTop,
    bool backLink = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (backLink) _BackLink(onPressed: onBack),
      _Eyebrow(copy.eyebrow),
      const SizedBox(height: AppAuthLayout.eyebrowGap),
      _Headline(lead: copy.headline, accent: copy.accent, size: size),
      SizedBox(height: fieldsTop),
    ],
  );

  Widget _phone(BuildContext context) => _Backdrop(
    rings: AppAuthLayout.phoneRings,
    ringsCentre: (size) => Offset(
      size.width - AppAuthLayout.phoneRingsFromTopEnd.dx,
      AppAuthLayout.phoneRingsFromTopEnd.dy,
    ),
    child: _FillScroll(
      builder: (minHeight) => form(
        fieldIcons: false,
        dense: true,
        builder: (context, fields, submit) => ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppAuthLayout.phonePaddingH,
              AppAuthLayout.phonePaddingTop,
              AppAuthLayout.phonePaddingH,
              AppAuthLayout.phonePaddingBottom,
            ),
            // Fields at the top, actions at the bottom (the mock's
            // `margin-top: auto`); scrolls when it cannot fit.
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        // The phone mocks' "All sign-in options" link, as an
                        // icon so the wordmark and controls keep the row.
                        IconButton(
                          tooltip: _backLabel,
                          onPressed: onBack,
                          icon: const Icon(
                            Icons.arrow_back,
                            size: AppIconSize.md,
                          ),
                        ),
                        const Expanded(child: _Wordmark()),
                        const AuthAppearanceControl(),
                        const _HelpButton(),
                      ],
                    ),
                    const SizedBox(height: AppAuthLayout.phoneHeaderTop),
                    _formHeader(
                      context,
                      AppAuthLayout.phoneDisplaySize,
                      fieldsTop: AppAuthLayout.phoneFieldsTop,
                      backLink: false,
                    ),
                    fields,
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      submit,
                      // The phone SignUp mock has no "or" rule.
                      _after(context, privacyLink: true, divider: !signUp),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _wideForm(BuildContext context, {required bool privacyLink}) => form(
    fieldIcons: true,
    dense: false,
    builder: (context, fields, submit) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _formHeader(context, AppAuthLayout.wideDisplaySize),
        fields,
        const SizedBox(height: AppSpacing.lg),
        submit,
        _after(context, privacyLink: privacyLink),
      ],
    ),
  );

  Widget _tablet(BuildContext context) => _Backdrop(
    rings: AppAuthLayout.wideRings,
    ringsCentre: (size) => Offset(
      size.width - AppAuthLayout.tabletRingsFromTopEnd.dx,
      AppAuthLayout.tabletRingsFromTopEnd.dy,
    ),
    child: _FillScroll(
      builder: (minHeight) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppAuthLayout.tabletPaddingH,
            vertical: AppAuthLayout.tabletPaddingV,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Expanded(child: _Wordmark()),
                  AuthAppearanceControl(),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppAuthLayout.tabletFormWidth,
                  ),
                  child: _wideForm(context, privacyLink: false),
                ),
              ),
              const _Footer(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _desktop(BuildContext context, double width) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: AppAuthLayout.desktopHeroFlex,
            child: _DesktopHero(
              eyebrow: copy.eyebrow,
              headline: copy.heroHeadline,
              accent: copy.heroAccent,
              width:
                  width *
                  AppAuthLayout.desktopHeroFlex /
                  (AppAuthLayout.desktopHeroFlex +
                      AppAuthLayout.desktopFormFlex),
            ),
          ),
          Expanded(
            flex: AppAuthLayout.desktopFormFlex,
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: SafeArea(
                child: Stack(
                  children: [
                    _FillScroll(
                      builder: (minHeight) => ConstrainedBox(
                        constraints: BoxConstraints(minHeight: minHeight),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppAuthLayout.desktopFormPaddingH,
                            vertical: AppAuthLayout.desktopHeroPaddingV,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: AppAuthLayout.desktopFormWidth,
                                ),
                                child: _wideForm(context, privacyLink: false),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const PositionedDirectional(
                      top: AppSpacing.md,
                      end: AppSpacing.md,
                      child: AuthAppearanceControl(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The auth pages' frame for a page that is not sign-in or sign-up (Create
/// profile, Account deleted), from the same mocks: a phone page with the
/// [actions] pinned to the bottom, a centred tablet column between the
/// wordmark and the footer, and the desktop hero + form split. The words of
/// the form header and of the hero are the caller's.
class AuthFrame extends StatelessWidget {
  const AuthFrame({
    super.key,
    required this.eyebrow,
    required this.headline,
    required this.accent,
    required this.heroEyebrow,
    required this.heroHeadline,
    required this.heroAccent,
    required this.children,
    required this.actions,
    this.headlineTail = '.',
    this.mark,
    this.phoneAction,
    this.wideFooter,
  });

  final String eyebrow;
  final String headline;
  final String accent;
  final String heroEyebrow;
  final String heroHeadline;
  final String heroAccent;

  /// Between the headline and the actions.
  final List<Widget> children;

  /// The buttons, full width.
  final Widget actions;

  /// What follows the accent word of the headline.
  final String headlineTail;

  /// The brand mark of the welcome page: centred under the wordmark on the
  /// phone (the text and actions then sit at the bottom, with the mark above
  /// the free space), above the eyebrow on tablet and in the desktop hero.
  final Widget? mark;

  /// At the top end of the phone page (Sign out).
  final Widget? phoneAction;

  /// Under [actions] on tablet and desktop (Sign out).
  final Widget? wideFooter;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        switch (AuthLook.of(constraints.maxWidth)) {
          AuthLook.phone => _phone(context),
          AuthLook.tablet => _tablet(context),
          AuthLook.desktop => _desktop(context, constraints.maxWidth),
        },
  );

  Widget _header(double size, {double fieldsTop = AppAuthLayout.fieldsTop}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Eyebrow(eyebrow),
          const SizedBox(height: AppAuthLayout.eyebrowGap),
          _Headline(
            lead: headline,
            accent: accent,
            size: size,
            tail: headlineTail,
          ),
          SizedBox(height: fieldsTop),
        ],
      );

  Widget _body() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (i, child) in children.indexed) ...[
        if (i > 0) const SizedBox(height: AppAuthLayout.phoneFieldGap),
        child,
      ],
    ],
  );

  Widget _wide({bool withMark = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (withMark && mark != null) ...[
        Align(alignment: AlignmentDirectional.centerStart, child: mark),
        const SizedBox(height: AppWelcomeLayout.wideMarkGap),
      ],
      _header(AppAuthLayout.wideDisplaySize),
      _body(),
      const SizedBox(height: AppSpacing.lg),
      actions,
      ?wideFooter,
    ],
  );

  Widget _phoneText() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _header(
        AppAuthLayout.phoneDisplaySize,
        fieldsTop: AppAuthLayout.phoneFieldsTop,
      ),
      _body(),
    ],
  );

  Widget _phone(BuildContext context) => _Backdrop(
    rings: AppAuthLayout.phoneRings,
    ringsCentre: (size) => Offset(
      size.width - AppAuthLayout.phoneRingsFromTopEnd.dx,
      AppAuthLayout.phoneRingsFromTopEnd.dy,
    ),
    child: _FillScroll(
      builder: (minHeight) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppAuthLayout.phonePaddingH,
            AppAuthLayout.phonePaddingTop,
            AppAuthLayout.phonePaddingH,
            AppAuthLayout.phonePaddingBottom,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: _Wordmark()),
                      ?phoneAction,
                    ],
                  ),
                  if (mark != null) ...[
                    const SizedBox(height: AppWelcomeLayout.phoneMarkTop),
                    Center(child: mark),
                  ] else ...[
                    const SizedBox(height: AppAuthLayout.phoneHeaderTop),
                    _phoneText(),
                  ],
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (mark != null) ...[
                      _phoneText(),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    actions,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _tablet(BuildContext context) => _Backdrop(
    rings: AppAuthLayout.wideRings,
    ringsCentre: (size) => Offset(
      size.width - AppAuthLayout.tabletRingsFromTopEnd.dx,
      AppAuthLayout.tabletRingsFromTopEnd.dy,
    ),
    child: _FillScroll(
      builder: (minHeight) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppAuthLayout.tabletPaddingH,
            vertical: AppAuthLayout.tabletPaddingV,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(children: [Expanded(child: _Wordmark())]),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppAuthLayout.tabletFormWidth,
                  ),
                  child: _wide(withMark: true),
                ),
              ),
              const _Footer(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _desktop(BuildContext context, double width) => Scaffold(
    body: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: AppAuthLayout.desktopHeroFlex,
          child: _DesktopHero(
            eyebrow: heroEyebrow,
            headline: heroHeadline,
            accent: heroAccent,
            mark: mark,
            width:
                width *
                AppAuthLayout.desktopHeroFlex /
                (AppAuthLayout.desktopHeroFlex + AppAuthLayout.desktopFormFlex),
          ),
        ),
        Expanded(
          flex: AppAuthLayout.desktopFormFlex,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: _FillScroll(
                builder: (minHeight) => ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppAuthLayout.desktopFormPaddingH,
                      vertical: AppAuthLayout.desktopHeroPaddingV,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: AppAuthLayout.desktopFormWidth,
                          ),
                          child: _wide(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// The phone and tablet page: the hero wash on dark (the mocks), the plain
/// surface on light, with teal rings behind the content.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.rings,
    required this.ringsCentre,
    required this.child,
  });

  final List<(double, double)> rings;
  final Offset Function(Size size) ringsCentre;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          gradient: dark ? AppGradients.hero : null,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: AppRings(
                rings: rings,
                color: context.appColors.accentText,
                centre: ringsCentre,
              ),
            ),
            SafeArea(child: child),
          ],
        ),
      ),
    );
  }
}

/// A scroll view whose child is told the viewport height, so a column can
/// fill the screen and still scroll when it is taller (large text, small
/// screens, the keyboard).
class _FillScroll extends StatelessWidget {
  const _FillScroll({required this.builder});

  final Widget Function(double minHeight) builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        SingleChildScrollView(child: builder(constraints.maxHeight)),
  );
}

/// The desktop brand panel: always the dark hero (desktop SignIn / SignUp
/// `section.hero`), whatever the appearance.
class _DesktopHero extends StatelessWidget {
  const _DesktopHero({
    required this.eyebrow,
    required this.headline,
    required this.accent,
    required this.width,
    this.mark,
  });

  final String eyebrow;
  final String headline;
  final String accent;
  final double width;
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    final textWidth = width - 2 * AppAuthLayout.desktopHeroPaddingH;
    final size = (textWidth / 9).clamp(
      AppAuthLayout.heroDisplayMin,
      AppAuthLayout.heroDisplayMax,
    );
    return Theme(
      data: buildAppTheme(brightness: Brightness.dark),
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          return DecoratedBox(
            decoration: const BoxDecoration(gradient: AppGradients.hero),
            child: Stack(
              children: [
                Positioned.fill(
                  child: AppRings(
                    rings: AppAuthLayout.wideRings,
                    color: context.appColors.accentText,
                    centre: (size) => Offset(
                      math.min(380, size.width / 2),
                      size.height * .55,
                    ),
                  ),
                ),
                SafeArea(
                  child: _FillScroll(
                    builder: (minHeight) => ConstrainedBox(
                      constraints: BoxConstraints(minHeight: minHeight),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppAuthLayout.desktopHeroPaddingH,
                          vertical: AppAuthLayout.desktopHeroPaddingV,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const _Wordmark(),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: AppSpacing.xl,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (mark != null) ...[
                                    mark!,
                                    const SizedBox(
                                      height: AppWelcomeLayout.wideMarkGap,
                                    ),
                                  ],
                                  _Eyebrow(eyebrow),
                                  const SizedBox(height: AppSpacing.md),
                                  // The form panel carries the page heading;
                                  // this one is decoration for readers.
                                  _Headline(
                                    lead: headline,
                                    accent: accent,
                                    size: size,
                                    header: false,
                                  ),
                                  const SizedBox(height: AppSpacing.lg),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: AppAuthLayout.heroBodyWidth,
                                    ),
                                    child: Text(
                                      AuthCopy.heroBody,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            fontSize:
                                                AppAuthLayout.heroBodySize,
                                            height: 1.5,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const _Footer(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Text('DZEROTH', style: AppTextStyles.wordmark(Theme.of(context))),
  );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: AppTextStyles.eyebrow(Theme.of(context))
        .copyWith(color: context.appColors.accentText),
  );
}

class _Headline extends StatelessWidget {
  const _Headline({
    required this.lead,
    required this.accent,
    required this.size,
    this.header = true,
    this.tail = '.',
  });

  final String lead;
  final String accent;
  final double size;
  final bool header;
  final String tail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.displayLarge!.copyWith(
      fontSize: size,
      letterSpacing: AppTypeTokens.displayTracking * size,
      color: theme.colorScheme.onSurface,
    );
    return Semantics(
      header: header,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: lead),
            TextSpan(
              text: accent,
              style: TextStyle(color: context.appColors.accentText),
            ),
            TextSpan(text: tail),
          ],
        ),
        style: base,
      ),
    );
  }
}

/// A rule with a word in the middle ("or", "or keep it classic").
class AuthOrDivider extends StatelessWidget {
  const AuthOrDivider({super.key, this.label = 'or'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppAuthLayout.dividerGap),
      // The label wraps at large text instead of overflowing; the rules keep
      // what is left.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            const Expanded(child: Divider(height: 1)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .7),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.smd),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const Expanded(child: Divider(height: 1)),
          ],
        ),
      ),
    );
  }
}

/// "New here? Sign up": a muted question and an accent action.
class AuthSwitchLine extends StatelessWidget {
  const AuthSwitchLine({
    super.key,
    required this.prompt,
    required this.action,
    required this.onPressed,
  });

  final String prompt;
  final String action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          prompt,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: context.appColors.accentText,
          ),
          child: Text(action),
        ),
      ],
    );
  }
}

const _backLabel = 'All sign-in options';

/// "← All sign-in options" above the eyebrow (the SignIn and SignUp mocks).
class _BackLink extends StatelessWidget {
  const _BackLink({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: context.appColors.accentText,
        padding: const EdgeInsetsDirectional.only(end: AppSpacing.sm),
      ),
      icon: const Icon(Icons.arrow_back, size: AppIconSize.md),
      label: const Text(_backLabel),
    ),
  );
}

/// "© year DZEROTH · Privacy Policy · Help" (tablet and desktop mocks).
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final link = TextButton.styleFrom(
      foregroundColor: theme.colorScheme.onSurfaceVariant,
      textStyle: muted,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('© ${DateTime.now().year} DZEROTH', style: muted),
        Text(' · ', style: muted),
        TextButton(
          style: link,
          onPressed: () => launchPrivacyPolicy(context),
          child: const Text('Privacy Policy'),
        ),
        Text(' · ', style: muted),
        TextButton(
          style: link,
          onPressed: () => showAuthHelp(context),
          child: const Text('Help'),
        ),
      ],
    );
  }
}

class _HelpButton extends StatelessWidget {
  const _HelpButton();

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Help',
    onPressed: () => showAuthHelp(context),
    icon: const Icon(Icons.help_outline, size: AppIconSize.md),
  );
}

/// What the auth pages offer, with the Privacy Policy.
void showAuthHelp(BuildContext context) => showAppMaterialDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('A plan starts here.'),
    content: const Text(
      'Log in or sign up with your email, or continue with an available '
      'provider. New email accounts need verification before you can '
      'continue.',
    ),
    actions: [
      TextButton(
        onPressed: () => launchPrivacyPolicy(context),
        child: const Text('Privacy Policy'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Got it'),
      ),
    ],
  ),
);

/// Light, Dark or System, before there is a Settings screen to reach.
class AuthAppearanceControl extends StatelessWidget {
  const AuthAppearanceControl({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ThemeModeCubit?>();
    if (cubit == null) return const SizedBox.shrink();
    return BlocBuilder<ThemeModeCubit, ThemeMode>(
      builder: (context, mode) => PopupMenuButton<ThemeMode>(
        tooltip: 'Appearance',
        initialValue: mode,
        onSelected: cubit.select,
        icon: Icon(switch (mode) {
          ThemeMode.light => Icons.light_mode_outlined,
          ThemeMode.dark => Icons.dark_mode_outlined,
          ThemeMode.system => Icons.brightness_auto_outlined,
        }, size: AppIconSize.md),
        itemBuilder: (_) => [
          for (final choice in [
            ThemeMode.light,
            ThemeMode.dark,
            ThemeMode.system,
          ])
            CheckedPopupMenuItem(
              value: choice,
              checked: choice == mode,
              child: Text(
                choice == ThemeMode.system ? 'System' : themeModeLabel(choice),
              ),
            ),
        ],
      ),
    );
  }
}
