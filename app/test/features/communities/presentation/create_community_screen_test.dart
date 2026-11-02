import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/create_community_screen.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

/// W5-31: Create a Community at 360 / 600 / 1200 dp, light and dark, text
/// scale 1.0 / 1.3 / 2.0.
void main() {
  late _MockCommunities repo;

  setUpAll(() {
    registerFallbackValue(<pb.CommunityRule>[]);
  });

  setUp(() {
    repo = _MockCommunities();
    when(() => repo.enabled).thenReturn(true);
  });

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) => pumpThemed(
    tester,
    RepositoryProvider<CommunitiesRepository>.value(
      value: repo,
      child: const CreateCommunityScreen(),
    ),
    brightness: env?.brightness ?? Brightness.light,
    size: env?.size ?? const Size(360, 800),
    textScale: env?.textScale ?? 1.0,
    useScaffold: false,
  );

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> fillName(WidgetTester tester, [String name = 'Chess club']) =>
      tester.enterText(field('Name'), name);

  bool createEnabled(WidgetTester tester) {
    final button = tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, 'Create'),
    );
    return button.onPressed != null;
  }

  forEachThemeAndWidth(
    'the form with two rules fits',
    (tester, env) async {
      final semantics = tester.ensureSemantics();
      await open(tester, env: env);
      await tester.tap(find.text('Add a rule'));
      await tester.pump();
      await tester.tap(find.text('Add a rule'));
      await tester.pump();

      expectNoOverflow(tester);
      expect(find.text('Create a Community'), findsOneWidget);
      expect(find.text('Rule 1'), findsOneWidget);
      expect(find.text('Rule 2'), findsOneWidget);
      expect(find.byTooltip('Remove rule 2'), findsOneWidget);
      semantics.dispose();
    },
    textScales: kMatrixTextScalesLarge,
    height: 3000,
  );

  testWidgets('Create needs a valid name', (tester) async {
    await open(tester);
    expect(createEnabled(tester), isFalse);
    await fillName(tester);
    await tester.pump();
    expect(createEnabled(tester), isTrue);
  });

  testWidgets('an over-long name shows the limit and blocks Create', (
    tester,
  ) async {
    await open(tester);
    await fillName(tester, 'x' * 31);
    await tester.pump();
    expect(createEnabled(tester), isFalse);
    expect(find.textContaining('30'), findsWidgets);
  });

  testWidgets('rules: add up to 10, then the button says so; remove works', (
    tester,
  ) async {
    await open(tester);
    for (var i = 0; i < 10; i++) {
      await tester.ensureVisible(find.textContaining('rule').last);
      await tester.tap(find.text(i == 0 ? 'Add a rule' : 'Add a rule'));
      await tester.pump();
    }
    expect(find.text('Most rules added (10)'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Remove rule 10'));
    await tester.tap(find.byTooltip('Remove rule 10'));
    await tester.pump();
    expect(find.text('Add a rule'), findsOneWidget);
  });

  testWidgets('an invisible character in the description or a rule text '
      'shows an error and blocks Create (W5-55b)', (tester) async {
    await open(tester);
    await fillName(tester);
    await tester.tap(find.text('Add a rule'));
    await tester.pump();
    await tester.enterText(field('Description'), 'a\u200Bb');
    await tester.enterText(field('Rule 1 title'), 'Be kind');
    await tester.pump();
    expect(createEnabled(tester), isFalse);
    expect(
      find.text('Use plain text, with no invisible characters.'),
      findsOneWidget,
    );
    await tester.enterText(field('Description'), 'two\nlines');
    await tester.pump();
    expect(createEnabled(tester), isTrue);
    await tester.enterText(field('Rule 1 details'), 'a⁠b');
    await tester.pump();
    expect(createEnabled(tester), isFalse);
    expect(
      find.text('Use plain text, with no invisible characters.'),
      findsOneWidget,
    );
  });

  testWidgets('Create sends name, description and rules once', (tester) async {
    final answer = Completer<pb.CreateCommunityResponse>();
    when(
      () => repo.createCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        rules: any(named: 'rules'),
      ),
    ).thenAnswer((_) => answer.future);
    await open(tester);
    await fillName(tester);
    await tester.enterText(field('Description'), 'Openings and endgames');
    await tester.tap(find.text('Add a rule'));
    await tester.pump();
    await tester.enterText(field('Rule 1 title'), 'Be kind');
    await tester.enterText(field('Rule 1 details'), 'No insults.');
    await tester.pump();

    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pump();
    final captured =
        verify(
              () => repo.createCommunity(
                idempotencyKey: any(named: 'idempotencyKey'),
                name: 'Chess club',
                description: 'Openings and endgames',
                rules: captureAny(named: 'rules'),
              ),
            ).captured.single
            as List<pb.CommunityRule>;
    expect(captured.single.title, 'Be kind');
    expect(captured.single.text, 'No insults.');
    // In flight: the button is disabled, so a second tap sends nothing.
    expect(createEnabled(tester), isFalse);
    answer.completeError(const NetworkException('offline'));
    await tester.pumpAndSettle();
  });

  testWidgets('a failure keeps the form and shows a friendly message', (
    tester,
  ) async {
    when(
      () => repo.createCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        rules: any(named: 'rules'),
      ),
    ).thenThrow(
      const LimitReachedException('limit', quota: 'communities_owned'),
    );
    await open(tester);
    await fillName(tester);
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('You can own up to 2 communities.'), findsOneWidget);
    expect(find.text('Chess club'), findsOneWidget);
    expect(createEnabled(tester), isTrue);
  });

  testWidgets('a retry of the same payload reuses the idempotency key', (
    tester,
  ) async {
    final keys = <String>[];
    when(
      () => repo.createCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        rules: any(named: 'rules'),
      ),
    ).thenAnswer((invocation) async {
      keys.add(invocation.namedArguments[#idempotencyKey] as String);
      throw const NetworkException('offline');
    });
    await open(tester);
    await fillName(tester);
    await tester.pump();
    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppPillButton, 'Create'));
    await tester.pumpAndSettle();

    expect(keys.length, 2);
    expect(keys[0], keys[1]);
  });
}
