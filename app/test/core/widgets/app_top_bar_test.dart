import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/app_shell_scope.dart';
import 'package:dzeroth/core/widgets/app_top_bar.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/geometry.dart';
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

  Widget host({required Widget bar, VoidCallback? openDrawer}) {
    final page = Scaffold(appBar: bar as PreferredSizeWidget);
    return BlocProvider<OnboardingBloc>.value(
      value: onboarding,
      child: openDrawer == null
          ? page
          : AppShellScope(openDrawer: openDrawer, child: page),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required Widget bar,
    VoidCallback? openDrawer,
    Size size = const Size(360, 800),
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) => pumpThemed(
    tester,
    host(bar: bar, openDrawer: openDrawer),
    brightness: brightness,
    size: size,
    textScale: textScale,
    useScaffold: false,
  );

  group('AppTopBar', () {
    testWidgets('is a 53dp row with the title', (tester) async {
      await pump(tester, bar: const AppTopBar(title: 'Home'));

      expectSize(tester, find.byType(AppTopBar), height: AppSize.headerRow);
      expect(find.text('Home'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('has no avatar button outside the shell (no scope)', (
      tester,
    ) async {
      await pump(tester, bar: const AppTopBar(title: 'Home'));

      expect(find.byType(AppAvatar), findsNothing);
      expect(find.bySemanticsLabel('Account menu'), findsNothing);
    });

    testWidgets('narrow + shell: a 32dp avatar in a 48dp tap target opens '
        'the drawer', (tester) async {
      var opened = 0;
      await pump(
        tester,
        bar: const AppTopBar(title: 'Home'),
        openDrawer: () => opened++,
      );

      expectSize(tester, find.byType(AppAvatar), width: 32, height: 32);
      final target = find.ancestor(
        of: find.byType(AppAvatar),
        matching: find.byType(SizedBox),
      );
      expectSize(
        tester,
        target.first,
        width: AppSpacing.minTapTarget,
        height: AppSpacing.minTapTarget,
      );

      await tester.tap(find.byType(AppAvatar));
      expect(opened, 1);
    });

    testWidgets('the avatar button is announced as "Account menu"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        bar: const AppTopBar(title: 'Home'),
        openDrawer: () {},
      );

      expect(
        tester.getSemantics(find.byType(AppAvatar)),
        isSemantics(label: 'Account menu', isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('on a wide layout the avatar button is not drawn, even with '
        'a scope (the rail has the account chip)', (tester) async {
      await pump(
        tester,
        bar: const AppTopBar(title: 'Home'),
        openDrawer: () {},
        size: const Size(1200, 800),
      );

      expect(find.byType(AppAvatar), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('title is the page title style and a semantics header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, bar: const AppTopBar(title: 'Notifications'));

      final style = tester.widget<Text>(find.text('Notifications')).style!;
      expect(style.fontSize, 20);
      expect(style.fontWeight, FontWeight.w700);
      expect(
        tester.getSemantics(find.text('Notifications')),
        isSemantics(label: 'Notifications', isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('shows a secondary subtitle line', (tester) async {
      await pump(
        tester,
        bar: const AppTopBar(title: 'Alice', subtitle: '1,767 posts'),
      );

      expect(find.text('1,767 posts'), findsOneWidget);
      final style = tester.widget<Text>(find.text('1,767 posts')).style!;
      expect(style.color, appLightTheme.colorScheme.onSurfaceVariant);
    });

    testWidgets('actions are drawn at the end', (tester) async {
      await pump(
        tester,
        bar: AppTopBar(
          title: 'Home',
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
          ],
        ),
      );

      expect(
        tester.getRect(find.byIcon(Icons.search)).left,
        greaterThan(tester.getRect(find.text('Home')).right),
      );
    });

    testWidgets('the surface is the page colour at 92 % alpha, with the '
        'bottom hairline', (tester) async {
      await pump(
        tester,
        bar: const AppTopBar(title: 'Home'),
        brightness: Brightness.dark,
      );

      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppTopBar),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color!.a, closeTo(0.92, 0.01));
      expect(decoration.color!.withValues(alpha: 1), const Color(0xFF000000));
      expect(
        (decoration.border! as Border).bottom.color,
        appDarkTheme.colorScheme.outlineVariant,
      );
    });

    forEachThemeAndWidth('does not overflow at any width, theme or text '
        'scale', (tester, env) async {
      await pump(
        tester,
        bar: const AppTopBar(
          title: 'A rather long page title that must ellipsize',
          subtitle: 'and a long subtitle line as well',
        ),
        openDrawer: () {},
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expectNoOverflow(tester);
    });
  });

  group('AppTopBar.sliver', () {
    testWidgets('is a floating, snapping 53dp sliver app bar', (tester) async {
      await pumpThemed(
        tester,
        BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: AppShellScope(
            openDrawer: () {},
            child: CustomScrollView(slivers: [AppTopBar.sliver(title: 'Home')]),
          ),
        ),
        size: const Size(360, 800),
      );

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.floating, isTrue);
      expect(bar.snap, isTrue);
      expect(bar.toolbarHeight, AppSize.headerRow);
      expect(find.text('Home'), findsOneWidget);
      expect(find.byType(AppAvatar), findsOneWidget);
    });
  });
}
