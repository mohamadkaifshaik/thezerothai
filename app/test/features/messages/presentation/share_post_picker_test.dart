import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart' show E2eeFlag;
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/widgets/user_list_row.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/share_post_target.dart';
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart'
    show kRecipientFieldKey, kRecipientHandleRowKey;
import 'package:dzeroth/features/messages/presentation/share_post_picker.dart';
import 'package:dzeroth/features/messages/presentation/widgets/share_post_bar.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_encryption_device.dart';
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
  final identityRepo = _MockIdentity();
  final onboarding = _MockOnboardingBloc();
  final FakePeopleSource source;

  Future<void> open(
    WidgetTester tester, {
    Set<String> features = const {'messaging', 'graph', 'dm_post_share'},
    double width = 390,
    double height = 800,
    double textScale = 1,
    Brightness brightness = Brightness.light,
    // The encryption wiring of the tree (Task 14); none = today's picker.
    FakeEncryptedMessaging? port,
    FakeEncryptionDevice? device,
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
          RepositoryProvider<IdentityRepository>.value(value: identityRepo),
          RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
          RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
          if (device != null)
            RepositoryProvider<EncryptionDevice>.value(value: device),
          if (port != null)
            RepositoryProvider<EncryptedMessaging?>.value(value: port),
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

/// A person's name on a list row (the chosen-people chip has it too).
Finder _person(String name) =>
    find.descendant(of: find.byType(UserListRow), matching: find.text(name));

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

      await tester.tap(_person('User 1'));
      await tester.pump();
      await tester.tap(_person('User 3'));
      await tester.pump();

      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.text('Send (2)'), findsOneWidget);
      await tester.tap(_person('User 1'));
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
      // Tall, so the five chips and all six rows fit without scrolling.
      await rig.open(tester, height: 1400);

      for (var i = 1; i <= 6; i++) {
        await tester.tap(_person('User $i'));
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

      await tester.tap(_person('User 1'));
      await tester.tap(_person('User 2'));
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
      await tester.tap(_person('User 1'));
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

      await tester.tap(_person('User 1'));
      await tester.tap(_person('User 2'));
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

      await tester.tap(_person('User 1'));
      await tester.tap(_person('User 2'));
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

    testWidgets('chosen people show as chips that drop them', (tester) async {
      await _Rig().open(tester);
      await tester.tap(_person('User 1'));
      await tester.tap(_person('User 2'));
      await tester.pump();

      expect(find.byKey(const ValueKey('share-chip-u1')), findsOneWidget);
      expect(find.byKey(const ValueKey('share-chip-u2')), findsOneWidget);
      await tester.tap(find.byTooltip('Remove @user1'));
      await tester.pump();
      expect(find.byKey(const ValueKey('share-chip-u1')), findsNothing);
      expect(find.text('Send (1)'), findsOneWidget);
    });

    testWidgets('a pick the typed text hides still gets its result row '
        '(and Retry shows who failed)', (tester) async {
      final rig = _Rig();
      rig.repo.failures.add(const CannotMessageException());
      await rig.open(tester);
      await tester.tap(_person('User 1'));
      await tester.pump();

      // Nothing the caller follows matches "zzz": the list no longer shows
      // User 1, who is still chosen.
      await tester.enterText(find.byKey(kRecipientFieldKey), 'zzz');
      await tester.pump();
      expect(find.byType(UserListRow), findsNothing);
      expect(find.text('Send (1)'), findsOneWidget);

      await tester.tap(find.byKey(kShareSendButtonKey));
      await tester.pumpAndSettle();

      // The results list is the chosen people, found or not by the filter.
      expect(find.byType(UserListRow), findsOneWidget);
      expect(_person('User 1'), findsOneWidget);
      expect(find.text("Can't send"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('a person found through "Send to @handle" is chosen, sent '
        'to, and shown', (tester) async {
      final rig = _Rig();
      when(() => rig.identityRepo.getProfile(handle: 'zed_9')).thenAnswer(
        (_) async => identity.Profile(
          userId: 'u-zed',
          handle: 'zed_9',
          displayName: 'Zed',
        ),
      );
      await rig.open(tester);
      await tester.enterText(find.byKey(kRecipientFieldKey), 'zed_9');
      await tester.pump();

      expect(find.text('Send to @zed_9'), findsOneWidget);
      expect(find.text('Message @zed_9'), findsNothing);
      await tester.tap(find.byKey(kRecipientHandleRowKey));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-chip-u-zed')), findsOneWidget);

      await tester.tap(find.byKey(kShareSendButtonKey));
      await tester.pumpAndSettle();

      expect(rig.repo.sendRecipients, ['u-zed']);
      expect(find.text('Zed'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
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
            await tester.tap(_person('User 1'));
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

  group('on the tablet and desktop layout (ui_shell + ui_tablet on)', () {
    const features = {
      'messaging',
      'graph',
      'dm_post_share',
      kFeatureUiShell,
      kFeatureUiTablet,
    };
    for (final width in [1024.0, 1440.0]) {
      testWidgets('placed by the modal host, inside the window, and sends '
          '[${width.toInt()}dp]', (tester) async {
        final rig = _Rig();
        await rig.open(tester, features: features, width: width, height: 900);

        expect(tester.takeException(), isNull);
        final card = tester.getRect(find.byType(Dialog));
        expect(
          card.left >= 0 && card.right <= width,
          isTrue,
          reason: 'the card is inside the window: $card',
        );
        expect(card.top >= 0 && card.bottom <= 900, isTrue);
        expect(find.text('Send in a message'), findsOneWidget);

        await tester.tap(_person('User 1'));
        await tester.pump();
        await tester.tap(find.text('Send (1)'));
        await tester.pumpAndSettle();
        expect(rig.repo.sendRecipients, ['u1']);
        expect(find.text('Sent'), findsOneWidget);

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('Send in a message'), findsNothing);
      });
    }
  });

  // Plan 5b Task 14: the share goes through the port only with the server's
  // check live (`e2ee_dm` AND `dm_share_check`).
  group('with the encryption wiring', () {
    const base = {'messaging', 'graph', 'dm_post_share'};

    Future<_Rig> shareTo(
      WidgetTester tester, {
      required Set<String> features,
      FakeEncryptedMessaging? port,
      FakeEncryptionDevice? device,
    }) async {
      final rig = _Rig();
      await rig.open(tester, features: features, port: port, device: device);
      await tester.tap(_person('User 1'));
      await tester.pump();
      await tester.tap(find.text('Send (1)'));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('both flags on: the check runs once, then the port sends the '
        'checked id', (tester) async {
      final port = FakeEncryptedMessaging();
      final rig = _Rig();
      rig.repo.checkAnswer = '9999999999999999999';
      await rig.open(
        tester,
        features: {...base, 'e2ee_dm', 'dm_share_check'},
        port: port,
        device: FakeEncryptionDevice(),
      );
      await tester.tap(_person('User 1'));
      await tester.pump();
      await tester.tap(find.text('Send (1)'));
      await tester.pumpAndSettle();
      expect(rig.repo.checkedPosts, [_postId]);
      expect(port.calls, contains('send'));
      expect(rig.repo.sendRecipients, isEmpty);
      expect(find.text('Sent'), findsOneWidget);
    });

    testWidgets('e2ee_dm on, dm_share_check off: the share ends with the '
        'flag-off line and nothing is called', (tester) async {
      final port = FakeEncryptedMessaging();
      final rig = await shareTo(
        tester,
        features: {...base, 'e2ee_dm'},
        port: port,
        device: FakeEncryptionDevice(),
      );
      expect(rig.repo.checkedPosts, isEmpty);
      expect(rig.repo.sendRecipients, isEmpty);
      expect(port.calls, isEmpty);
      expect(
        find.text("Sending a post in a message isn't available right now."),
        findsWidgets,
      );
    });

    testWidgets('dm_share_check on, e2ee_dm off, a vault here (manage): '
        'the same flag-off line, zero calls', (tester) async {
      final port = FakeEncryptedMessaging();
      final rig = await shareTo(
        tester,
        features: {...base, 'dm_share_check'},
        port: port,
        device: FakeEncryptionDevice(flag: E2eeFlag.off),
      );
      expect(rig.repo.checkedPosts, isEmpty);
      expect(rig.repo.sendRecipients, isEmpty);
      expect(port.calls, isEmpty);
    });

    testWidgets('no vault on the device and the flags off (hidden): today\'s '
        'plain share, the port is never touched', (tester) async {
      final port = FakeEncryptedMessaging();
      final rig = await shareTo(
        tester,
        features: base,
        port: port,
        device: FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off),
      );
      expect(rig.repo.checkedPosts, isEmpty);
      expect(rig.repo.sendRecipients, ['u1']);
      expect(port.calls, isEmpty);
      expect(find.text('Sent'), findsOneWidget);
    });

    testWidgets('no wiring in the tree: today\'s plain share', (tester) async {
      final rig = await shareTo(tester, features: base);
      expect(rig.repo.sendRecipients, ['u1']);
      expect(rig.repo.checkedPosts, isEmpty);
    });
  });
}
