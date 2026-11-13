import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/share_post_target.dart';
import 'package:dzeroth/features/messages/presentation/share_post_picker.dart';
import 'package:dzeroth/features/messages/presentation/widgets/share_post_bar.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_people_source.dart';
import '../../../support/fake_send_repository.dart';
import '../../../support/messaging_fixtures.dart';

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

const _me = 'u-me';
const _postId = '1234567890123456789';
const _url = 'https://dzeroth.com/post/$_postId';
const _target = SharePostTarget(postId: _postId, url: _url);

/// The "Send in a message" dialog, opened from a button, over fakes.
class _Rig {
  _Rig({FakePeopleSource? source})
    : source =
          source ?? FakePeopleSource(people: [person(1), person(2), person(3)]);

  final repo = FakeSendRepository();
  final onboarding = _MockOnboardingBloc();
  final FakePeopleSource source;

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'messaging', 'graph', 'dm_post_share'},
    double width = 390,
    double height = 800,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: features,
        profile: identity.Profile(userId: _me, handle: 'me'),
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
          child: MediaQuery(
            data: MediaQueryData(
              size: Size(width, height),
              textScaler: TextScaler.linear(textScale),
            ),
            child: MaterialApp(
              theme: buildAppTheme(brightness: brightness),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => unawaited(
                      showSharePostPicker(
                        context,
                        target: _target,
                        source: source,
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}

Finder get _send => find.byKey(kShareSendButtonKey);

void main() {
  setUpAll(() => registerFallbackValue(const <String>[]));

  group('the share picker', () {
    testWidgets('lists the Following rows with a check, no Message pill', (
      tester,
    ) async {
      await _Rig().open(tester);

      expect(find.text('Send in a message'), findsOneWidget);
      expect(find.text('Message'), findsNothing);
      expect(find.byType(UserListRow), findsNWidgets(3));
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(3));
      expect(find.byKey(kShareCaptionFieldKey), findsOneWidget);
      expect(tester.widget<AppPillButton>(_send).onPressed, isNull);
    });

    testWidgets('choosing people checks them and counts them on Send', (
      tester,
    ) async {
      await _Rig().open(tester);

      await tester.tap(find.text('User 1'));
      await tester.pump();
      await tester.tap(find.text('User 3'));
      await tester.pump();

      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.text('Send (2)'), findsOneWidget);
      await tester.tap(find.text('User 1'));
      await tester.pump();
      expect(find.text('Send (1)'), findsOneWidget);
    });

    testWidgets('a sixth person is not chosen and the hint says why', (
      tester,
    ) async {
      final rig = _Rig(
        source: FakePeopleSource(
          people: [for (var i = 1; i <= 6; i++) person(i)],
        ),
      );
      await rig.open(tester);

      for (var i = 1; i <= 6; i++) {
        await tester.ensureVisible(find.text('User $i'));
        await tester.tap(find.text('User $i'));
        await tester.pump();
      }

      expect(find.byIcon(Icons.check_circle), findsNWidgets(5));
      expect(find.text('Send (5)'), findsOneWidget);
      expect(find.textContaining('up to 5 people'), findsOneWidget);
    });

    testWidgets('Send sends one by one with a result per row, the caption as '
        'text, then Done closes', (tester) async {
      final rig = _Rig();
      await rig.open(tester);

      await tester.tap(find.text('User 1'));
      await tester.tap(find.text('User 2'));
      await tester.pump();
      await tester.enterText(find.byKey(kShareCaptionFieldKey), 'look');
      await tester.tap(find.text('Send (2)'));
      await tester.pumpAndSettle();

      expect(rig.repo.sendRecipients, ['u1', 'u2']);
      expect(rig.repo.sendSharedPostIds, [_postId, _postId]);
      expect(rig.repo.sendTexts, ['look', 'look']);
      expect(rig.repo.sendKeys.toSet(), hasLength(2));
      expect(find.text('Sent'), findsNWidgets(2));
      expect(find.text('Done'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Send in a message'), findsNothing);
    });

    testWidgets('no caption: the post link is the text', (tester) async {
      final rig = _Rig();
      await rig.open(tester);
      await tester.tap(find.text('User 1'));
      await tester.pump();
      await tester.tap(find.text('Send (1)'));
      await tester.pumpAndSettle();
      expect(rig.repo.sendTexts, [_url]);
    });

    testWidgets('a refused person shows the reason and Retry sends only '
        'that row, with the same key', (tester) async {
      final rig = _Rig();
      rig.repo.failures.add(const CannotMessageException());
      await rig.open(tester);

      await tester.tap(find.text('User 1'));
      await tester.tap(find.text('User 2'));
      await tester.pump();
      await tester.tap(find.text('Send (2)'));
      await tester.pumpAndSettle();

      expect(find.text("Can't send"), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text(CannotMessageException.userMessage), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(rig.repo.sendRecipients, ['u1', 'u2', 'u1']);
      expect(rig.repo.sendKeys[2], rig.repo.sendKeys[0]);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('a protected post: the whole share stops, the rest are '
        '"Not sent"', (tester) async {
      final rig = _Rig();
      rig.repo.failures.add(const ProtectedAccountException());
      await rig.open(tester);

      await tester.tap(find.text('User 1'));
      await tester.tap(find.text('User 2'));
      await tester.pump();
      await tester.tap(find.text('Send (2)'));
      await tester.pumpAndSettle();

      expect(rig.repo.sendKeys, hasLength(1));
      expect(find.text('Not sent'), findsNWidgets(2));
      expect(
        find.textContaining('Only the author can send a protected'),
        findsOneWidget,
      );
    });

    testWidgets('"Recent" lists the cached inbox people first, once', (
      tester,
    ) async {
      final rig = _Rig();
      // u-a is "Peer a" in the cache; Following also has u1.
      rig.repo.cachedInbox = [conv('a'), conv('b')];
      await rig.open(tester);

      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Suggested'), findsOneWidget);
      expect(find.text('Peer a'), findsOneWidget);
      expect(find.text('Peer b'), findsOneWidget);
      await tester.tap(find.text('Peer a'));
      await tester.pump();
      await tester.tap(find.text('Send (1)'));
      await tester.pumpAndSettle();
      expect(rig.repo.sendRecipients, ['u-a']);
    });

    testWidgets('the caller never appears under Recent', (tester) async {
      final rig = _Rig();
      rig.repo.cachedInbox = [conv('a')];
      rig.repo.cachedInbox.first.peer.userId = _me;
      await rig.open(tester);
      expect(find.text('Recent'), findsNothing);
    });

    testWidgets('without dm_post_share: a short "not available" line, no '
        'send', (tester) async {
      final rig = _Rig();
      await rig.open(tester, features: const {'messaging', 'graph'});

      expect(find.byKey(kShareSendButtonKey), findsNothing);
      expect(find.byType(UserListRow), findsNothing);
      expect(find.text("Messages aren't available yet"), findsOneWidget);
      expect(rig.repo.sendKeys, isEmpty);
    });

    testWidgets('without messaging: the same line', (tester) async {
      await _Rig().open(tester, features: const {'dm_post_share'});
      expect(find.byKey(kShareSendButtonKey), findsNothing);
      expect(find.text("Messages aren't available yet"), findsOneWidget);
    });
  });

  group('the share picker at 3 widths', () {
    for (final width in [390.0, 1024.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('no overflow, look follows the width '
              '[${width.toInt()}dp x$scale ${brightness.name}]', (
            tester,
          ) async {
            final rig = _Rig();
            rig.repo.cachedInbox = [conv('a')];
            await rig.open(
              tester,
              width: width,
              height: 900,
              textScale: scale,
              brightness: brightness,
            );
            await tester.tap(find.text('User 1'));
            await tester.pump();

            expect(tester.takeException(), isNull);
            // The phone's title case; the card's uppercase section label.
            expect(
              find.text(width < 600 ? 'Recent' : 'RECENT'),
              findsOneWidget,
            );
            expect(find.text('Send in a message'), findsOneWidget);
            expect(find.byKey(kShareSendButtonKey), findsOneWidget);
            // The To: pill leads only in the card.
            expect(
              find.text('To:'),
              width < 600 ? findsNothing : findsOneWidget,
            );
          });
        }
      }
    }
  });
}
