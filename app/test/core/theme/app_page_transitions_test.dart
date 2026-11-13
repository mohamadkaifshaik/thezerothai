import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openSecond(WidgetTester tester, {bool reduce = false}) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: appLightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
          child: child!,
        ),
        home: const Scaffold(body: Text('First')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Second')),
      ),
    );
    await tester.pump();
  }

  Finder fadeAround(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byType(FadeTransition),
  );

  double opacityOf(WidgetTester tester, String text) => tester
      .widgetList<FadeTransition>(fadeAround(text))
      .map((f) => f.opacity.value)
      .reduce((a, b) => a < b ? a : b);

  testWidgets('a pushed page fades in over the token duration', (tester) async {
    await openSecond(tester);
    await tester.pump(AppMotion.pageTransition ~/ 4);
    final mid = opacityOf(tester, 'Second');
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'Second'), 1);
  });

  testWidgets('reduced motion: no fade and no slide', (tester) async {
    await openSecond(tester, reduce: true);
    await tester.pump(AppMotion.pageTransition ~/ 4);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Second'),
          matching: find.byType(PageStorage),
        ),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    expect(
      tester
          .widgetList<FadeTransition>(fadeAround('Second'))
          .where((f) => f.opacity.value < 1),
      isEmpty,
    );
  });

  testWidgets('the profile skeleton holds still under reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appLightTheme,
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: ProfileSkeleton()),
        ),
      ),
    );
    expect(find.byKey(kProfileSkeletonKey), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
