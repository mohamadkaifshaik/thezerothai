import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/presentation/bloc/create_community_cubit.dart';
import 'package:dzeroth/features/communities/presentation/create_community_screen.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_text_field.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/theme_harness.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

pb.Community _existing() => pb.Community(
  communityId: '7',
  name: 'Chess club',
  description: 'Weekly games',
);

final _rules = [pb.CommunityRule(title: 'Be kind', text: 'No insults')];

void main() {
  late _MockCommunities repo;

  setUpAll(() => registerFallbackValue(<pb.CommunityRule>[]));

  setUp(() {
    repo = _MockCommunities();
    when(() => repo.enabled).thenReturn(true);
    when(
      () => repo.updateCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: any(named: 'communityId'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        rules: any(named: 'rules'),
      ),
    ).thenAnswer(
      (i) async => pb.UpdateCommunityResponse(
        community: pb.Community(
          communityId: '7',
          name: (i.namedArguments[#name] as String?) ?? 'Chess club',
        ),
      ),
    );
  });

  CreateCommunityCubit cubit() => CreateCommunityCubit(
    repository: repo,
    existing: _existing(),
    existingRules: _rules,
  );

  group('CreateCommunityCubit editing', () {
    test('sends only the fields that changed', () async {
      final c = cubit();
      await c.create(name: 'Chess', description: 'Weekly games', rules: _rules);
      final call = verify(
        () => repo.updateCommunity(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: '7',
          name: captureAny(named: 'name'),
          description: captureAny(named: 'description'),
          rules: captureAny(named: 'rules'),
        ),
      )..called(1);
      expect(call.captured, ['Chess', null, null]);
      expect(c.state.created?.communityId, '7');
      await c.close();
    });

    test('rules are sent as a whole set when they changed', () async {
      final c = cubit();
      await c.create(
        name: 'Chess club',
        description: 'Weekly games',
        rules: const [],
      );
      final call = verify(
        () => repo.updateCommunity(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: '7',
          name: captureAny(named: 'name'),
          description: captureAny(named: 'description'),
          rules: captureAny(named: 'rules'),
        ),
      );
      expect(call.captured[0], isNull);
      expect(call.captured[1], isNull);
      expect(call.captured[2], isEmpty);
      await c.close();
    });

    test('nothing changed sends no call and closes', () async {
      final c = cubit();
      await c.create(
        name: 'Chess club',
        description: 'Weekly games',
        rules: _rules,
      );
      verifyNever(
        () => repo.updateCommunity(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: any(named: 'communityId'),
        ),
      );
      expect(c.state.created, isNotNull);
      await c.close();
    });

    test('a refusal shows its text and keeps the form', () async {
      when(
        () => repo.updateCommunity(
          idempotencyKey: any(named: 'idempotencyKey'),
          communityId: any(named: 'communityId'),
          name: any(named: 'name'),
          description: any(named: 'description'),
          rules: any(named: 'rules'),
        ),
      ).thenThrow(const NotFoundException('gone'));
      final c = cubit();
      await c.create(name: 'New', description: 'Weekly games', rules: _rules);
      expect(c.state.error, isNotNull);
      expect(c.state.created, isNull);
      expect(c.state.busy, isFalse);
      await c.close();
    });
  });

  testWidgets('the edit form is prefilled and saves', (tester) async {
    await pumpThemed(
      tester,
      RepositoryProvider<CommunitiesRepository>.value(
        value: repo,
        child: CreateCommunityScreen(
          existing: _existing(),
          existingRules: _rules,
        ),
      ),
      useScaffold: false,
      size: const Size(400, 1400),
    );
    expect(find.text('Edit community'), findsOneWidget);
    expect(find.text('Chess club'), findsOneWidget);
    expect(find.text('Weekly games'), findsOneWidget);
    expect(find.text('RULE 1'), findsOneWidget);
    final save = tester.widget<AppPillButton>(
      find.widgetWithText(AppPillButton, 'Save'),
    );
    // Nothing differs yet: Save waits (as the Lists editor).
    expect(save.onPressed, isNull);

    final name = find.descendant(
      of: find.byWidgetPredicate((w) => w is AppTextField && w.label == 'Name'),
      matching: find.byType(TextField),
    );
    await tester.enterText(name, 'Chess');
    await tester.pump();
    expect(
      tester
          .widget<AppPillButton>(find.widgetWithText(AppPillButton, 'Save'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
    await tester.pump();
    verify(
      () => repo.updateCommunity(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '7',
        name: 'Chess',
        description: null,
        rules: null,
      ),
    ).called(1);
  });
}
