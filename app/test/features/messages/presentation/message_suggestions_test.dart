import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/message_suggestions.dart';
import 'package:dzeroth/features/messages/domain/people_source.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_suggestions_cubit.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_people_source.dart';
import '../../../support/fake_send_repository.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

pb.MessageSuggestion _s(
  String id,
  MessageSuggestionReason reason, {
  BeaconActivity? activity,
  String community = '',
}) => pb.MessageSuggestion(
  user: common.AuthorSnapshot(
    userId: id,
    handle: 'h$id',
    displayName: 'Person $id',
  ),
  reason: reason,
  planActivity: activity,
  communityName: community,
);

const _recent =
    MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_RECENT_CONVERSATION;
const _plan = MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_MET_ON_PLAN;
const _mutual = MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_MUTUAL_FOLLOW;
const _community =
    MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_COMMUNITY_MEMBER;

class _FailingSource extends FakePeopleSource {
  @override
  Future<PeoplePage> page({
    required int pageSize,
    required String pageToken,
  }) async => throw const NetworkException('offline');
}

class _Rig {
  _Rig({FakePeopleSource? source})
    : source = source ?? FakePeopleSource(people: [person(1)]);

  final repo = FakeSendRepository();
  final onboarding = _MockOnboardingBloc();
  final FakePeopleSource source;
  final picked = <String>[];

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'messaging', 'graph', 'dm_suggestions'},
    Size size = const Size(390, 844),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: 'u-me', handle: 'me'),
      ),
    );
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<MessagingRepository>.value(value: repo),
          RepositoryProvider<IdentityRepository>.value(value: _MockIdentity()),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MaterialApp(
            theme: buildAppTheme(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: RecipientPicker(
                source: source,
                dialog: size.width >= 600,
                onPicked: (context, peer) => picked.add(peer.userId),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void main() {
  group('messageSuggestionReason', () {
    test('one short subtitle per reason', () {
      expect(messageSuggestionReason(_s('1', _recent)), 'Recent conversation');
      expect(
        messageSuggestionReason(_s('1', _mutual)),
        'You follow each other',
      );
      expect(
        messageSuggestionReason(_s('1', _community, community: 'Runners')),
        'In Runners',
      );
      expect(
        messageSuggestionReason(_s('1', _community)),
        'In a community you joined',
      );
    });

    test('a plan reads with its activity, generic for other or unknown', () {
      expect(
        messageSuggestionReason(
          _s('1', _plan, activity: BeaconActivity.BEACON_ACTIVITY_COFFEE),
        ),
        'Met on a coffee plan',
      );
      expect(messageSuggestionReason(_s('1', _plan)), 'Met on a plan');
      expect(
        messageSuggestionReason(
          _s('1', _plan, activity: BeaconActivity.BEACON_ACTIVITY_OTHER),
        ),
        'Met on a plan',
      );
    });

    test('an unknown reason has no subtitle', () {
      expect(
        messageSuggestionReason(
          _s(
            '1',
            MessageSuggestionReason.MESSAGE_SUGGESTION_REASON_UNSPECIFIED,
          ),
        ),
        isNull,
      );
    });
  });

  group('MessageSuggestionsCubit', () {
    test('loads once, drops the caller and repeats', () async {
      final repo = FakeSendRepository()
        ..suggestions = [_s('me', _recent), _s('a', _recent), _s('a', _mutual)];
      final cubit = MessageSuggestionsCubit(repository: repo, ownUserId: 'me');
      await cubit.load();
      expect(cubit.state.status, MessageSuggestionsStatus.ready);
      expect(cubit.state.suggestions.map((s) => s.user.userId), ['a']);
      expect(repo.suggestionLimits, [kMessageSuggestionsLimit]);
      await cubit.close();
    });

    test('every failure is quiet', () async {
      final repo = FakeSendRepository()
        ..suggestionsError = const RateLimitedException('slow');
      final cubit = MessageSuggestionsCubit(repository: repo);
      await cubit.load();
      expect(cubit.state.status, MessageSuggestionsStatus.failed);
      expect(cubit.state.suggestions, isEmpty);
      await cubit.close();
    });
  });

  group('the picker section', () {
    testWidgets('flag off: no call, today picker', (tester) async {
      final rig = _Rig();
      rig.repo.suggestions = [_s('9', _recent)];
      await rig.open(tester, features: const {'messaging', 'graph'});
      expect(rig.repo.suggestionLimits, isEmpty);
      expect(find.text('Person 9'), findsNothing);
      expect(find.text('Suggested'), findsOneWidget);
      expect(find.text('Following'), findsNothing);
      expect(find.text('User 1'), findsOneWidget);
    });

    testWidgets('flag on: rows with reasons before the Following list', (
      tester,
    ) async {
      final rig = _Rig();
      rig.repo.suggestions = [
        _s('9', _recent),
        _s('8', _plan, activity: BeaconActivity.BEACON_ACTIVITY_COFFEE),
        _s('7', _community, community: 'Runners'),
      ];
      await rig.open(tester);
      expect(rig.repo.suggestionLimits, [kMessageSuggestionsLimit]);
      expect(find.text('Suggested'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('Recent conversation'), findsOneWidget);
      expect(find.text('Met on a coffee plan'), findsOneWidget);
      expect(find.text('In Runners'), findsOneWidget);
      final suggested = tester.getTopLeft(find.text('Person 9')).dy;
      expect(suggested, lessThan(tester.getTopLeft(find.text('User 1')).dy));
      // A tap picks the person, as any picker row does.
      await tester.tap(find.text('Person 8'));
      await tester.pump();
      expect(rig.picked, ['8']);
    });

    testWidgets('typing hides the section', (tester) async {
      final rig = _Rig();
      rig.repo.suggestions = [_s('9', _recent)];
      await rig.open(tester);
      await tester.enterText(find.byKey(kRecipientFieldKey), 'user');
      await tester.pump();
      expect(find.text('Person 9'), findsNothing);
    });

    testWidgets('nobody followed: the suggestions still show', (tester) async {
      final rig = _Rig(source: FakePeopleSource());
      rig.repo.suggestions = [_s('9', _recent)];
      await rig.open(tester);
      expect(find.text('Person 9'), findsOneWidget);
      expect(find.text('Recent conversation'), findsOneWidget);
      expect(find.text('Following'), findsNothing);
    });

    testWidgets('the Following list failing: the suggestions still show', (
      tester,
    ) async {
      final rig = _Rig(source: _FailingSource());
      rig.repo.suggestions = [_s('9', _recent)];
      await rig.open(tester);
      expect(find.text('Person 9'), findsOneWidget);
      await tester.tap(find.text('Person 9'));
      await tester.pump();
      expect(rig.picked, ['9']);
    });

    testWidgets('empty list or an error: the picker is unchanged', (
      tester,
    ) async {
      final empty = _Rig();
      await empty.open(tester);
      expect(find.text('Following'), findsNothing);
      expect(find.text('Suggested'), findsOneWidget);

      final failing = _Rig();
      failing.repo.suggestionsError = const NetworkException('offline');
      await failing.open(tester);
      expect(find.text('Following'), findsNothing);
      expect(find.text('User 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final MapEntry(key: name, value: size) in const {
      'phone': Size(390, 844),
      'tablet': Size(1024, 768),
      'desktop': Size(1440, 900),
    }.entries) {
      for (final brightness in Brightness.values) {
        for (final scale in const [1.0, 2.0]) {
          testWidgets('layout $name ${brightness.name} x$scale', (
            tester,
          ) async {
            final rig = _Rig();
            rig.repo.suggestions = [
              _s('9', _recent),
              _s('8', _community, community: 'A community with a long name'),
            ];
            await rig.open(
              tester,
              size: size,
              brightness: brightness,
              textScale: scale,
            );
            expect(find.text('Recent conversation'), findsOneWidget);
            final dialog = size.width >= 600;
            expect(
              find.text(dialog ? 'SUGGESTED' : 'Suggested'),
              findsOneWidget,
            );
            expect(
              find.text(dialog ? 'FOLLOWING' : 'Following'),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });
}
