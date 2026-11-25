import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/icons/dz_icons.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_round_action.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/dz_finders.dart';
import '../../support/theme_harness.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late _MockOnboardingBloc onboarding;

  setUp(() {
    onboarding = _MockOnboardingBloc();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(userId: 'u1', handle: 'alice'),
      ),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    required PreferredSizeWidget Function(BuildContext) bar,
    VoidCallback? openDrawer,
    double width = 390,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) {
    final page = Builder(builder: (context) => Scaffold(appBar: bar(context)));
    return pumpThemed(
      tester,
      BlocProvider<OnboardingBloc>.value(
        value: onboarding,
        child: openDrawer == null
            ? page
            : AppShellScope(openDrawer: openDrawer, child: page),
      ),
      size: Size(width, 844),
      brightness: brightness,
      textScale: textScale,
      useScaffold: false,
    );
  }

  PreferredSizeWidget screenBar(BuildContext context) => AppTopBar.of(
    context,
    style: AppTopBarStyle.screen,
    title: 'Plans',
    actions: [
      AppRoundAction(
        icon: DzIcons.calendar,
        tooltip: 'My plans',
        onPressed: () {},
      ),
    ],
  );

  group('screen variant', () {
    testWidgets('content-box row as the canvas renders it (60 + 8 + 8, then '
        'the 1 dp hairline): 40 dp avatar, 24/800 Jakarta title, a 44 dp '
        'round action with a 48 dp tap area', (tester) async {
      await pump(tester, bar: screenBar, openDrawer: () {});
      final bar = tester.getRect(find.byType(AppTopBar));
      expect(bar.height, 76 + 1);
      expect(AppSize.dzHeaderRow, 76);
      // The row's content is centred in the 76 dp above the hairline.
      expect(tester.getRect(find.byType(AppRoundAction)).center.dy, 38);
      expect(tester.getSize(find.byType(AppAvatar)), const Size.square(40));
      final title = tester.widget<Text>(find.text('Plans'));
      expect(title.style?.fontSize, 24);
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(title.style?.fontFamily, AppFonts.heading);
      expect(
        tester.getSize(find.byType(AppRoundAction)),
        const Size.square(44),
      );
      expect(
        tapAreaOf(
          tester,
          find.descendant(
            of: find.byType(AppRoundAction),
            matching: find.byType(InkResponse),
          ),
        ).size,
        const Size.square(AppSpacing.minTapTarget),
      );
      // 12 dp from the start, 12 from the end; the title between.
      expect(tester.getRect(find.byType(AppAvatar)).left, 12);
      expect(tester.getRect(find.byType(AppRoundAction)).right, 390 - 12);
      expect(
        tester.getRect(find.text('Plans')).left,
        closeTo(12 + 40 + 8 + 4, 12),
      );
    });

    testWidgets('the avatar still opens the drawer', (tester) async {
      var opened = 0;
      await pump(tester, bar: screenBar, openDrawer: () => opened++);
      await tester.tap(find.byType(AppAvatar));
      expect(opened, 1);
    });

    testWidgets('the round action has the soft shadow and fires', (
      tester,
    ) async {
      var taps = 0;
      await pump(
        tester,
        openDrawer: () {},
        bar: (context) => AppTopBar.of(
          context,
          style: AppTopBarStyle.screen,
          title: 'Plans',
          actions: [
            AppRoundAction(
              icon: DzIcons.calendar,
              tooltip: 'My plans',
              onPressed: () => taps++,
            ),
          ],
        ),
      );
      final decorated = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppRoundAction),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(
        (decorated.decoration as ShapeDecoration).shadows,
        AppShadows.softRaised,
      );
      await tester.tap(find.byType(AppRoundAction));
      expect(taps, 1);
    });

    testWidgets('no avatar outside the shell or on wide layouts', (
      tester,
    ) async {
      await pump(tester, bar: screenBar);
      expect(find.byType(AppAvatar), findsNothing);
      await pump(tester, bar: screenBar, openDrawer: () {}, width: 834);
      expect(find.byType(AppAvatar), findsNothing);
      expect(find.text('Plans'), findsOneWidget);
    });

    testWidgets('the title is a header, the action has its name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, bar: screenBar, openDrawer: () {});
      expect(
        tester.getSemantics(find.text('Plans')),
        matchesSemantics(label: 'Plans', isHeader: true),
      );
      expect(find.bySemanticsLabel('My plans'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('grows with the text scale instead of overflowing', (
      tester,
    ) async {
      await pump(tester, bar: screenBar, openDrawer: () {}, textScale: 2);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byType(AppTopBar)).height, greaterThan(77));
    });
  });

  group('back variant', () {
    PreferredSizeWidget backBar(BuildContext context, {VoidCallback? onBack}) =>
        AppTopBar.of(
          context,
          style: AppTopBarStyle.back,
          title: 'Settings',
          onBack: onBack,
        );

    testWidgets('44 dp back arrow with a 48 dp tap area, Inter 22/800 title '
        '(the Z back headers), no avatar', (tester) async {
      await pump(tester, bar: backBar, openDrawer: () {});
      expect(find.byType(AppAvatar), findsNothing);
      expect(tester.getRect(find.byType(AppTopBar)).height, 76 + 1);
      expect(tester.getSize(findDz(DzIcons.back)), const Size.square(22));
      final arrow = tester.getRect(
        find
            .ancestor(
              of: findDz(DzIcons.back),
              matching: find.byType(InkResponse),
            )
            .first,
      );
      expect(arrow.size, const Size.square(44));
      expect(arrow.left, 8);
      final area = tapAreaOf(tester, findDz(DzIcons.back));
      expect(area.size, const Size.square(AppSpacing.minTapTarget));
      expect(area.center, arrow.center);
      final title = tester.widget<Text>(find.text('Settings'));
      expect(title.style?.fontSize, 22);
      expect(title.style?.fontWeight, FontWeight.w800);
      expect(title.style?.letterSpacing, closeTo(-0.4, 1e-9));
      expect(title.style?.fontFamily, AppFonts.body);
    });

    testWidgets('the ring around the arrow takes a tap; the semantics node '
        'is 48 dp', (tester) async {
      final handle = tester.ensureSemantics();
      var backs = 0;
      await pump(tester, bar: (c) => backBar(c, onBack: () => backs++));
      final arrow = tester.getRect(
        find
            .ancestor(
              of: findDz(DzIcons.back),
              matching: find.byType(InkResponse),
            )
            .first,
      );
      await tester.tapAt(arrow.bottomCenter + const Offset(0, 1.5));
      expect(backs, 1, reason: 'below the arrow');
      // In the row's 8 dp start padding, outside the Row's own bounds.
      await tester.tapAt(arrow.centerLeft - const Offset(1.5, 0));
      expect(backs, 2, reason: 'before the arrow');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Back')).rect.size,
        const Size.square(AppSpacing.minTapTarget),
      );
      handle.dispose();
    });

    testWidgets('DzSettings: a Jakarta 24/800 title through titleStyle', (
      tester,
    ) async {
      await pump(
        tester,
        bar: (c) => AppTopBar.of(
          c,
          style: AppTopBarStyle.back,
          title: 'Settings',
          titleStyle: AppTextStyles.dzBackTitleSettings(Theme.of(c)),
        ),
      );
      final title = tester.widget<Text>(find.text('Settings'));
      expect(title.style?.fontSize, 24);
      expect(title.style?.fontFamily, AppFonts.heading);
      expect(title.style?.letterSpacing, 0);
      expect(tester.getRect(find.byType(AppTopBar)).height, 76 + 1);
    });

    testWidgets('the arrow calls onBack, named Back', (tester) async {
      final handle = tester.ensureSemantics();
      var backs = 0;
      await pump(tester, bar: (c) => backBar(c, onBack: () => backs++));
      expect(find.bySemanticsLabel('Back'), findsOneWidget);
      await tester.tap(findDz(DzIcons.back));
      expect(backs, 1);
      handle.dispose();
    });

    testWidgets('without onBack the arrow pops the route', (tester) async {
      await pumpThemed(
        tester,
        BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                appBar: AppTopBar(style: AppTopBarStyle.back, title: 'Pushed'),
                body: const Text('pushed body'),
              ),
            ),
          ),
        ),
        useScaffold: false,
      );
      // A single route cannot pop; the arrow must not throw.
      await tester.tap(findDz(DzIcons.back));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('sliver form', () {
    testWidgets('screen style as a sliver', (tester) async {
      await pumpThemed(
        tester,
        BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: AppShellScope(
            openDrawer: () {},
            child: CustomScrollView(
              slivers: [
                AppTopBar.sliver(
                  style: AppTopBarStyle.screen,
                  title: 'Explore',
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
        useScaffold: false,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Explore'), findsOneWidget);
      expect(tester.getSize(find.byType(AppAvatar)), const Size.square(40));
    });
  });

  for (final width in [360.0, 834.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('both variants lay out at $width (${brightness.name})', (
        tester,
      ) async {
        await pump(
          tester,
          bar: screenBar,
          openDrawer: () {},
          width: width,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        await pump(
          tester,
          bar: (c) =>
              AppTopBar.of(c, style: AppTopBarStyle.back, title: 'Back'),
          width: width,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
