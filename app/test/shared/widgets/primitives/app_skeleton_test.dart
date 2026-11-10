import 'package:dzeroth/shared/widgets/post/post_list_skeleton.dart';
import 'package:dzeroth/shared/widgets/primitives/app_skeleton.dart';
import 'package:dzeroth/shared/widgets/user/user_list_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

void main() {
  forEachThemeAndWidth(
    'skeletons fit without overflow and announce once',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        const SingleChildScrollView(
          child: Column(children: [PostListSkeleton(), UserListSkeleton()]),
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
        disableAnimations: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Loading posts'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading people'), findsOneWidget);
      await expectGolden(tester, find.byType(Column).first, 'skeletons', env);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  testWidgets('reduced motion: no animation ticker, blocks are static', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: PostListSkeleton()),
        ),
      ),
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('with motion the pulse runs, then comes to rest', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: UserListSkeleton())),
    );
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(AppSkeletonScope.period * AppSkeletonScope.cycles);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('the pulse follows a later reduced-motion change', (
    tester,
  ) async {
    Widget host({required bool reduce}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: const Scaffold(body: UserListSkeleton()),
      ),
    );
    await tester.pumpWidget(host(reduce: false));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(host(reduce: true));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a block outside a scope is static and keeps its size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AppSkeletonBlock(width: 40, height: 40, circle: true),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(AppSkeletonBlock)), const Size(40, 40));
    expect(tester.binding.transientCallbackCount, 0);
  });
}
