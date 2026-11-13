import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_icon_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contrast.dart';
import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

typedef _BarBuilder = PreferredSizeWidget Function(BuildContext context);

void main() {
  late _MockOnboardingBloc onboarding;

  setUp(() {
    onboarding = _MockOnboardingBloc();
  });

  /// Seeds the flags: `ui_shell` on is the redesign, off the legacy chrome.
  void seed({required bool uiShell}) {
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        enabledFeatures: {if (uiShell) kFeatureUiShell},
        profile: identity.Profile(userId: 'u1', handle: 'alice'),
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required _BarBuilder bar,
    required bool uiShell,
    VoidCallback? openDrawer,
    Size size = const Size(360, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) {
    seed(uiShell: uiShell);
    final page = Builder(builder: (context) => Scaffold(appBar: bar(context)));
    return pumpThemed(
      tester,
      BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: openDrawer == null
            ? page
            : AppShellScope(openDrawer: openDrawer, child: page),
      ),
      brightness: brightness,
      size: size,
      textScale: textScale,
      useScaffold: false,
    );
  }

  Future<void> pumpSliver(
    WidgetTester tester, {
    required Widget sliver,
    required bool uiShell,
    double textScale = 1,
    Size size = const Size(360, 800),
  }) {
    seed(uiShell: uiShell);
    return pumpThemed(
      tester,
      BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: AppShellScope(
          openDrawer: () {},
          child: CustomScrollView(slivers: [sliver]),
        ),
      ),
      size: size,
      textScale: textScale,
    );
  }

  BoxDecoration surfaceOf(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(AppTopBar),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    return box.decoration as BoxDecoration;
  }

  Finder inBar(Finder matching) =>
      find.descendant(of: find.byType(AppTopBar), matching: matching);

  group('AppTopBar (ui_shell on)', () {
    testWidgets('is a 53dp row with the title at text scale 1.0', (
      tester,
    ) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
      );

      expectSize(tester, find.byType(AppTopBar), height: AppSize.headerRow);
      expect(find.text('Notifications'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('has no avatar button outside the shell (no scope)', (
      tester,
    ) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
      );

      expect(find.byType(AppAvatar), findsNothing);
      expect(find.bySemanticsLabel('Open account menu'), findsNothing);
    });

    testWidgets('narrow + shell: a 36dp avatar in a 48dp tap target opens '
        'the drawer', (tester) async {
      var opened = 0;
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
        openDrawer: () => opened++,
      );

      expectSize(tester, find.byType(AppAvatar), width: 36, height: 36);
      expectSize(
        tester,
        find.byType(AppAvatarButton),
        width: AppSpacing.minTapTarget,
        height: AppSpacing.minTapTarget,
        tolerance: 0,
      );

      await tester.tap(find.byType(AppAvatar));
      expect(opened, 1);
    });

    testWidgets('the avatar button is announced as "Open account menu"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
        openDrawer: () {},
      );

      expect(
        tester.getSemantics(find.byType(AppAvatar)),
        isSemantics(
          label: 'Open account menu',
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('on a wide layout the avatar button is not drawn, even with '
        'a scope (the rail has the account chip)', (tester) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
        openDrawer: () {},
        size: const Size(1200, 800),
      );

      expect(find.byType(AppAvatar), findsNothing);
      expect(find.text('Notifications'), findsOneWidget);
    });

    testWidgets('title is Manrope titleLarge w800 and a semantics header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
      );

      final style = tester.widget<Text>(find.text('Notifications')).style!;
      expect(style.fontSize, appLightTheme.textTheme.titleLarge!.fontSize);
      expect(style.fontWeight, AppTypeTokens.weightDisplay);
      expect(style.fontWeight, FontWeight.w800);
      expect(style.fontFamily, AppFonts.display);
      // Weight through `fontWeight` only (ADR-0033 amendment 2).
      expect(style.fontVariations, isNull);
      expect(
        tester.getSemantics(find.text('Notifications')),
        isSemantics(label: 'Notifications', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('shows a secondary subtitle line', (tester) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) =>
            AppTopBar.of(context, title: 'Alice', subtitle: '1,767 posts'),
      );

      final style = tester.widget<Text>(find.text('1,767 posts')).style!;
      expect(style.color, appLightTheme.colorScheme.onSurfaceVariant);
      expectSize(tester, find.byType(AppTopBar), height: AppSize.headerRow);
    });

    for (final brightness in Brightness.values) {
      testWidgets('the surface is the page colour at 88 % alpha, with the '
          'bottom hairline, and the title keeps AA contrast '
          '(${brightness.name})', (tester) async {
        await pump(
          tester,
          uiShell: true,
          bar: (context) => AppTopBar.of(context, title: 'Notifications'),
          brightness: brightness,
        );
        final scheme = buildAppTheme(brightness: brightness).colorScheme;

        final decoration = surfaceOf(tester);
        expect(decoration.color!.a, closeTo(0.88, 0.005));
        expect(decoration.color!.withValues(alpha: 1), scheme.surface);
        expect(decoration.gradient, isNull);
        expect(
          (decoration.border! as Border).bottom.color,
          scheme.outlineVariant,
        );
        // No blur (decision D4 of W0).
        expect(inBar(find.byType(BackdropFilter)), findsNothing);
        expect(
          contrast(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });
    }

    testWidgets('at text scale 2.0 the bar grows and the title is not '
        'scaled down', (tester) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Notifications'),
        openDrawer: () {},
        textScale: 2,
      );

      // titleLarge is 20 sp on a 1.25 line: 50dp at 2.0, plus 2 x 4dp.
      expectSize(tester, find.byType(AppTopBar), height: 58, tolerance: 0);
      expect(
        tester.getSize(find.byType(AppTopBar)).height,
        greaterThan(AppSize.headerRow),
      );
      expect(inBar(find.byType(FittedBox)), findsNothing);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Notifications'),
      );
      expect(paragraph.textScaler, const TextScaler.linear(2));
      expect(paragraph.size.height, closeTo(50, 0.5));
      // The paragraph is painted at its own size: no ancestor transform.
      expect(
        paragraph.getTransformTo(null).getMaxScaleOnAxis(),
        closeTo(1, 0.0001),
      );
      expectMinTarget(tester, find.byType(AppAvatarButton));
      expectNoOverflow(tester);
    });

    testWidgets('at text scale 2.0 a title plus a subtitle grows further', (
      tester,
    ) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) =>
            AppTopBar.of(context, title: 'Alice', subtitle: '1,767 posts'),
        textScale: 2,
      );

      // 2 x (25 + 19.6) + 8 = 97.2, rounded up.
      expectSize(tester, find.byType(AppTopBar), height: 98, tolerance: 0);
      expect(inBar(find.byType(FittedBox)), findsNothing);
      expect(
        tester.getRect(find.text('1,767 posts')).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(AppTopBar)).bottom),
      );
      expectNoOverflow(tester);
    });

    testWidgets('the body starts under the grown bar', (tester) async {
      seed(uiShell: true);
      await pumpThemed(
        tester,
        BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: Builder(
            builder: (context) => Scaffold(
              appBar: AppTopBar.of(context, title: 'Notifications'),
              body: const SizedBox.expand(key: Key('body')),
            ),
          ),
        ),
        size: const Size(360, 800),
        textScale: 2,
        useScaffold: false,
      );

      expect(tester.getRect(find.byKey(const Key('body'))).top, 58);
    });

    testWidgets('the fixed constructor cannot grow: a block taller than '
        '53dp at 2.0 is a loud overflow, not a silent clip or scale-down '
        '(use AppTopBar.of)', (tester) async {
      await pump(
        tester,
        uiShell: true,
        bar: (_) => const AppTopBar(title: 'Alice', subtitle: '1,767 posts'),
        textScale: 2,
      );

      expectSize(
        tester,
        find.byType(AppTopBar),
        height: AppSize.headerRow,
        tolerance: 0,
      );
      expect(inBar(find.byType(FittedBox)), findsNothing);
      expect(inBar(find.byType(ClipRect)), findsNothing);
      final error = tester.takeException();
      expect(error, isFlutterError);
      expect(error.toString(), contains('overflowed'));
    });

    testWidgets('the sliver overrides only the text scaler: the paddings '
        'are those inside the app bar', (tester) async {
      seed(uiShell: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: appLightTheme,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              padding: EdgeInsets.only(top: 24),
              textScaler: TextScaler.linear(2),
            ),
            child: BlocProvider<OnboardingBloc>.value(
              value: onboarding,
              child: Scaffold(
                body: CustomScrollView(
                  slivers: [AppTopBar.sliver(title: 'Notifications')],
                ),
              ),
            ),
          ),
        ),
      );

      final inner = MediaQuery.of(tester.element(find.text('Notifications')));
      expect(inner.textScaler, const TextScaler.linear(2));
      // The app bar's safe area consumed the status bar inset.
      expect(inner.padding.top, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('wordmark: draws DZEROTH centred in the wordmark style, '
        'named by the title as the header', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Home', wordmark: true),
        openDrawer: () {},
      );

      expect(find.text('Home'), findsNothing);
      final text = tester.widget<Text>(find.text('DZEROTH'));
      expect(text.style, AppTextStyles.wordmark(appLightTheme));
      expect(text.style!.fontWeight, AppTypeTokens.wordmarkWeight);
      expect(text.style!.fontVariations, isNull);
      expect(tester.getCenter(find.text('DZEROTH')).dx, closeTo(180, 1));
      expect(
        tester.getSemantics(find.text('DZEROTH')),
        isSemantics(label: 'Home', isHeader: true),
      );
      expect(find.bySemanticsLabel('DZEROTH'), findsNothing);
      handle.dispose();
    });

    testWidgets('wordmark without a title is left out of semantics (the '
        'screen has its own heading)', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, wordmark: true),
      );

      expect(find.text('DZEROTH'), findsOneWidget);
      expect(find.bySemanticsLabel('DZEROTH'), findsNothing);
      expect(
        find.semantics.byPredicate(
          (node) => node.flagsCollection.isHeader,
          describeMatch: (_) => 'a header node',
        ),
        findsNothing,
      );
      handle.dispose();
    });

    testWidgets('wordmark fits at 360dp and text scale 2.0', (tester) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(context, title: 'Home', wordmark: true),
        openDrawer: () {},
        textScale: 2,
      );

      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('DZEROTH'),
      );
      expect(paragraph.textScaler, const TextScaler.linear(2));
      expect(paragraph.didExceedMaxLines, isFalse);
      expectInsideHorizontally(tester, find.text('DZEROTH'), 360);
      expect(
        tester.getRect(find.text('DZEROTH')).left,
        greaterThanOrEqualTo(
          tester.getRect(find.byType(AppAvatarButton)).right,
        ),
      );
      expectNoOverflow(tester);
    });

    testWidgets('two AppTopBarActions keep an 8dp gap', (tester) async {
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(
          context,
          title: 'Messages',
          actions: [
            AppTopBarAction(
              icon: Icons.mail_outline,
              tooltip: 'New message',
              onPressed: () {},
            ),
            AppTopBarAction(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              onPressed: () {},
            ),
          ],
        ),
      );

      final first = tester.getRect(find.byTooltip('New message'));
      final second = tester.getRect(find.byTooltip('Settings'));
      expect(second.left - first.right, greaterThanOrEqualTo(AppSpacing.sm));
    });

    testWidgets('AppTopBarAction is a raised 48dp AppIconButton at the end', (
      tester,
    ) async {
      var pressed = 0;
      await pump(
        tester,
        uiShell: true,
        bar: (context) => AppTopBar.of(
          context,
          title: 'Messages',
          actions: [
            AppTopBarAction(
              icon: Icons.mail_outline,
              tooltip: 'New message',
              onPressed: () => pressed++,
            ),
          ],
        ),
      );

      final button = tester.widget<AppIconButton>(find.byType(AppIconButton));
      expect(button.raised, isTrue);
      expect(button.tooltip, 'New message');
      expectMinTarget(tester, find.byType(AppIconButton));
      expect(
        tester.getRect(find.byType(AppIconButton)).left,
        greaterThan(tester.getRect(find.text('Messages')).right),
      );
      expectInsideHorizontally(tester, find.byType(AppIconButton), 360);
      await tester.tap(find.byTooltip('New message'));
      expect(pressed, 1);
    });

    void matrix(
      String name, {
      required List<double> widths,
      required List<double> textScales,
      Map<double, double>? heights,
    }) {
      forEachThemeAndWidth(
        'does not overflow and keeps 48dp targets ($name)',
        (tester, env) async {
          await pump(
            tester,
            uiShell: true,
            bar: (context) => AppTopBar.of(
              context,
              title: 'A rather long page title that must ellipsize',
              subtitle: 'and a long subtitle line as well',
              actions: [
                AppTopBarAction(
                  icon: Icons.mail_outline,
                  tooltip: 'New message',
                  onPressed: () {},
                ),
              ],
            ),
            openDrawer: () {},
            size: env.size,
            brightness: env.brightness,
            textScale: env.textScale,
          );

          expectNoOverflow(tester);
          expect(inBar(find.byType(FittedBox)), findsNothing);
          expectMinTarget(tester, find.byType(AppIconButton));
          expectInsideHorizontally(
            tester,
            find.byType(AppIconButton),
            env.size.width,
          );
          final narrow = env.size.width < AppBreakpoints.mobile;
          expect(
            find.byType(AppAvatarButton),
            narrow ? findsOneWidget : findsNothing,
          );
          if (narrow) expectMinTarget(tester, find.byType(AppAvatarButton));
          final bar = tester.getRect(find.byType(AppTopBar));
          expect(
            bar.height,
            env.textScale > 1
                ? greaterThan(AppSize.headerRow)
                : AppSize.headerRow,
          );
          expect(
            tester
                .getRect(find.text('and a long subtitle line as well'))
                .bottom,
            lessThanOrEqualTo(bar.bottom),
          );
          await expectGolden(
            tester,
            find.byType(AppTopBar),
            'app_top_bar',
            env,
          );
        },
        widths: widths,
        textScales: textScales,
        heights: heights,
      );
    }

    matrix(
      'redesign widths',
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );
    matrix(
      '600 and 1200 boundaries',
      widths: kMatrixWidths,
      textScales: kMatrixTextScalesLarge,
    );

    forEachThemeAndWidth(
      'the wordmark bar does not overflow',
      (tester, env) async {
        await pump(
          tester,
          uiShell: true,
          bar: (context) =>
              AppTopBar.of(context, title: 'Home', wordmark: true),
          openDrawer: () {},
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expectNoOverflow(tester);
        expect(find.text('DZEROTH'), findsOneWidget);
        expectInsideHorizontally(tester, find.text('DZEROTH'), env.size.width);
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );
  });

  group('AppTopBar (ui_shell off, legacy chrome unchanged)', () {
    testWidgets('is a 53dp row with the title', (tester) async {
      await pump(
        tester,
        uiShell: false,
        bar: (_) => const AppTopBar(title: 'Home'),
      );

      expectSize(tester, find.byType(AppTopBar), height: AppSize.headerRow);
      expect(find.text('Home'), findsOneWidget);
      expect(find.byType(AppAvatar), findsNothing);
      expectNoOverflow(tester);
    });

    testWidgets('title is the page title style and a semantics header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        uiShell: false,
        bar: (_) => const AppTopBar(title: 'Notifications'),
      );

      final style = tester.widget<Text>(find.text('Notifications')).style!;
      final token = appLightTheme.textTheme.titleLarge!;
      expect(style.fontSize, token.fontSize);
      expect(style.fontWeight, token.fontWeight);
      expect(style.fontFamily, token.fontFamily);
      expect(style.height, token.height);
      expect(
        tester.getSemantics(find.text('Notifications')),
        isSemantics(label: 'Notifications', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('the surface stays the page colour at 92 % alpha, with the '
        'bottom hairline', (tester) async {
      await pump(
        tester,
        uiShell: false,
        bar: (_) => const AppTopBar(title: 'Home'),
        brightness: Brightness.dark,
      );

      final decoration = surfaceOf(tester);
      expect(decoration.color!.a, closeTo(0.92, 0.005));
      expect(
        decoration.color!.withValues(alpha: 1),
        appDarkTheme.colorScheme.surface,
      );
      expect(
        (decoration.border! as Border).bottom.color,
        appDarkTheme.colorScheme.outlineVariant,
      );
    });

    testWidgets('AppTopBar.of stays 53dp at text scale 2.0 and scales the '
        'title block down to fit', (tester) async {
      await pump(
        tester,
        uiShell: false,
        bar: (context) =>
            AppTopBar.of(context, title: 'Alice', subtitle: '1,767 posts'),
        textScale: 2,
      );

      expectSize(
        tester,
        find.byType(AppTopBar),
        height: AppSize.headerRow,
        tolerance: 0,
      );
      expect(inBar(find.byType(FittedBox)), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('wordmark is ignored: the title is drawn', (tester) async {
      await pump(
        tester,
        uiShell: false,
        bar: (context) => AppTopBar.of(context, title: 'Home', wordmark: true),
      );

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('DZEROTH'), findsNothing);
      // Not centred by the wordmark either.
      expect(tester.getRect(find.text('Home')).left, AppSpacing.md);
    });

    testWidgets('AppTopBarAction is the plain icon button', (tester) async {
      var pressed = 0;
      await pump(
        tester,
        uiShell: false,
        bar: (_) => AppTopBar(
          title: 'Messages',
          actions: [
            AppTopBarAction(
              icon: Icons.mail_outline,
              tooltip: 'New message',
              onPressed: () => pressed++,
            ),
          ],
        ),
      );

      expect(find.byType(AppIconButton), findsNothing);
      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.tooltip, 'New message');
      expect(button.style, isNull);
      expect(
        tester.getRect(find.byIcon(Icons.mail_outline)).left,
        greaterThan(tester.getRect(find.text('Messages')).right),
      );
      await tester.tap(find.byTooltip('New message'));
      expect(pressed, 1);
    });

    forEachThemeAndWidth(
      'does not overflow at any width, theme or text scale',
      (tester, env) async {
        await pump(
          tester,
          uiShell: false,
          bar: (_) => const AppTopBar(
            title: 'A rather long page title that must ellipsize',
            subtitle: 'and a long subtitle line as well',
          ),
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expectNoOverflow(tester);
        expectSize(
          tester,
          find.byType(AppTopBar),
          height: AppSize.headerRow,
          tolerance: 0,
        );
      },
      textScales: kMatrixTextScalesLarge,
    );
  });

  group('AppTopBar.sliver', () {
    testWidgets('ui_shell on: a floating, snapping 53dp sliver app bar at '
        '88 % alpha', (tester) async {
      await pumpSliver(
        tester,
        uiShell: true,
        sliver: AppTopBar.sliver(title: 'Notifications'),
      );

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.floating, isTrue);
      expect(bar.snap, isTrue);
      expect(bar.toolbarHeight, AppSize.headerRow);
      expect(bar.backgroundColor!.a, closeTo(0.88, 0.005));
      expect(
        bar.backgroundColor!.withValues(alpha: 1),
        appLightTheme.colorScheme.surface,
      );
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.byType(AppAvatar), findsOneWidget);
    });

    testWidgets('ui_shell on: grows at text scale 2.0 for a title alone', (
      tester,
    ) async {
      await pumpSliver(
        tester,
        uiShell: true,
        sliver: AppTopBar.sliver(title: 'Notifications'),
        textScale: 2,
      );

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.toolbarHeight, 58);
      expectSize(tester, find.byType(AppBar), height: 58, tolerance: 0);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('Notifications'),
      );
      expect(paragraph.textScaler, const TextScaler.linear(2));
      expect(
        find.descendant(
          of: find.byType(SliverAppBar),
          matching: find.byType(FittedBox),
        ),
        findsNothing,
      );
      expectNoOverflow(tester);
    });

    testWidgets('ui_shell on: grows further with a subtitle', (tester) async {
      await pumpSliver(
        tester,
        uiShell: true,
        sliver: AppTopBar.sliver(title: 'Alice', subtitle: '1,767 posts'),
        textScale: 2,
      );

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.toolbarHeight, 98);
      expectNoOverflow(tester);
    });

    testWidgets('ui_shell on: the wordmark replaces the title', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpSliver(
        tester,
        uiShell: true,
        sliver: AppTopBar.sliver(title: 'Home', wordmark: true),
      );

      expect(find.text('Home'), findsNothing);
      expect(
        tester.getSemantics(find.text('DZEROTH')),
        isSemantics(label: 'Home', isHeader: true),
      );
      expect(tester.getCenter(find.text('DZEROTH')).dx, closeTo(180, 1));
      handle.dispose();
    });

    testWidgets('ui_shell off: 53dp at 92 % alpha, fixed for a title alone '
        'at 2.0, no wordmark', (tester) async {
      await pumpSliver(
        tester,
        uiShell: false,
        sliver: AppTopBar.sliver(title: 'Home', wordmark: true),
        textScale: 2,
      );

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.floating, isTrue);
      expect(bar.snap, isTrue);
      expect(bar.toolbarHeight, AppSize.headerRow);
      expect(bar.backgroundColor!.a, closeTo(0.92, 0.005));
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('DZEROTH'), findsNothing);
    });

    testWidgets('ui_shell off: a subtitle still grows the row with the text '
        'scale', (tester) async {
      await pumpSliver(
        tester,
        uiShell: false,
        sliver: AppTopBar.sliver(title: 'Alice', subtitle: '1,767 posts'),
        textScale: 1.3,
      );

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.toolbarHeight, closeTo(AppSize.headerRow * 1.3, 0.001));
    });
  });
}
