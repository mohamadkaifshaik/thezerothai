import 'dart:async';
import 'dart:io';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/screen_names.dart';
import 'package:dzeroth/core/telemetry/usage_reporter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/recording_usage_analytics.dart';

void main() {
  group('screenNameForTemplate', () {
    test('maps templates and sends anything else to other', () {
      expect(screenNameForTemplate('/post/:id'), 'post_detail');
      expect(screenNameForTemplate('/u/:userId'), 'profile');
      expect(screenNameForTemplate('/messages/:id'), 'message_thread');
      expect(screenNameForTemplate('/search'), 'search');
      expect(screenNameForTemplate('/post/123'), kOtherScreen);
      expect(screenNameForTemplate('/unmapped/:id'), kOtherScreen);
      expect(screenNameForTemplate(null), kOtherScreen);
    });

    test('table names are lower snake case and keys are templates', () {
      for (final e in kScreenNames.entries) {
        expect(e.value, matches(RegExp(r'^[a-z][a-z_]*$')), reason: e.key);
        expect(e.key, startsWith('/'));
        expect(e.key, isNot(contains('?')));
      }
    });
  });

  test('every route constant and route path in AppRouter has a name', () {
    final source = File('lib/core/router/app_router.dart').readAsStringSync();
    final templates = <String>{
      for (final m in RegExp(
        r"static const \w+ = '(/[^'$]*)';",
      ).allMatches(source))
        m.group(1)!.split('?').first,
      for (final m in RegExp(r"path: '(/[^'$]*)',").allMatches(source))
        m.group(1)!,
      // `'$messagesPath/:id'` is built from a constant.
      '${AppRouter.messagesPath}/:id',
    };
    // `ScreenViewTracker` reads `GoRoute.path`, which is the whole template only
    // while every path is absolute (or built from a constant).
    final relative = RegExp(r"path: '([^'/$][^']*)',").allMatches(source);
    expect(
      relative.map((m) => m.group(1)),
      isEmpty,
      reason: 'a relative child path needs screen_names.dart to join it',
    );
    expect(templates.length, greaterThan(30), reason: 'the scan found routes');
    final names = {...kScreenNames.values, kOtherScreen};
    for (final t in templates) {
      expect(names, contains(screenNameForTemplate(t)), reason: t);
    }
    // A new route needs a row in kScreenNames, or an explicit decision here
    // that it is `other`.
    final unnamed = templates.where((t) => !kScreenNames.containsKey(t));
    expect(unnamed, isEmpty, reason: 'add these to kScreenNames: $unnamed');
  });

  group('router listener', () {
    late RecordingUsageAnalytics analytics;
    late GoRouter router;
    late ScreenViewTracker tracker;
    final seenByState = <String>[];

    GoRoute route(String path) => GoRoute(
      path: path,
      builder: (context, state) {
        seenByState.add(screenNameFor(state));
        return const Scaffold(body: SizedBox());
      },
    );

    setUp(() {
      analytics = RecordingUsageAnalytics();
      seenByState.clear();
      router = GoRouter(
        initialLocation: '/home',
        routes: [
          route('/home'),
          route('/post/:id'),
          route('/u/:userId'),
          route('/messages/:id'),
          route('/search'),
          route('/secret/:token'),
        ],
      );
      tracker = ScreenViewTracker(router, UsageReporter.analytics(analytics));
    });

    tearDown(() {
      tracker.dispose();
      router.dispose();
    });

    testWidgets('names screens from the template; no id, handle or query '
        'reaches the adapter', (tester) async {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      for (final location in [
        '/post/123',
        '/u/alice',
        '/messages/conv-9',
        '/search?q=%23secret&tab=latest',
        '/secret/abc',
      ]) {
        unawaited(router.push(location));
        await tester.pumpAndSettle();
      }

      expect(analytics.screens, [
        'home',
        'post_detail',
        'profile',
        'message_thread',
        'search',
        kOtherScreen,
      ]);
      final all = analytics.screens.join(' ');
      for (final leak in [
        '123',
        'alice',
        'conv-9',
        'secret',
        'abc',
        '?',
        'q=',
      ]) {
        expect(all, isNot(contains(leak)), reason: leak);
      }
      // `GoRouterState.fullPath` gives `screenNameFor` the same names.
      expect(seenByState, containsAll(['post_detail', 'profile', 'search']));
    });

    testWidgets('going back reports the page underneath once', (tester) async {
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      unawaited(router.push('/post/1'));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();
      expect(analytics.screens, ['home', 'post_detail', 'home']);
    });
  });
}
