import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_session.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_banner.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status_card.dart'
    show encryptionStatusBody, encryptionStatusTitle;
import 'package:dzeroth/features/messages/presentation/recipient_picker_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/features/messages/presentation/widgets/not_encrypted_note.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/encrypted_inbox_rig.dart';
import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/fake_people_source.dart';
import '../../../../support/fake_send_repository.dart';
import '../../../../support/messaging_fixtures.dart';

const _canary = 'canary preview words';

/// A port that records the ids of every `previews` call and can hold the answer.
class _Port extends FakeEncryptedMessaging {
  final List<List<String>> asked = [];
  Completer<void>? hold;

  @override
  Future<Map<String, ConversationPreview>> previews(
    Iterable<String> conversationIds,
  ) async {
    asked.add(conversationIds.toList());
    final held = hold;
    final answer = await super.previews(conversationIds);
    if (held != null) await held.future;
    return answer;
  }
}

pb.Conversation _enc(String id, {String snippet = ''}) =>
    conv(id, snippet: snippet)..lastMessage.encrypted = true;

String _line(ConversationsState s, pb.Conversation c) => conversationSnippet(
  c,
  preview: s.previews[c.id],
  knownEncrypted: s.knownEncrypted.contains(c.id),
);

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockIdentity extends Mock implements IdentityRepository {}

class _MockGraph extends Mock implements GraphRepository {}

void main() {
  group('the cubit', () {
    late EncryptedInboxRig rig;
    late _Port port;
    late List<Object> reported;
    final closers = <Future<void> Function()>[];

    setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));

    setUp(() {
      port = _Port();
      rig = EncryptedInboxRig(port: port);
      reported = [];
    });

    tearDown(() async {
      for (final close in closers) {
        await close();
      }
      closers.clear();
    });

    ConversationsCubit cubit({
      Folder folder = Folder.FOLDER_INBOX,
      bool withPort = true,
      bool Function()? allowed,
    }) {
      final c = ConversationsCubit(
        repository: rig.repo,
        folder: folder,
        encrypted: withPort ? port : null,
        previewsAllowed: allowed,
        onUnexpectedError: (error, _) => reported.add(error),
      );
      closers.add(c.close);
      return c;
    }

    test('previews are requested once per page for the encrypted rows '
        'only', () async {
      port.local = {'c'};
      rig.stub(
        network: [
          _enc('a'),
          conv('b', snippet: 'hi'),
          conv('c', snippet: 'x'),
        ],
        more: true,
      );
      when(() => rig.repo.loadOlderConversations(Folder.FOLDER_INBOX))
          .thenAnswer(
            (_) async => EncryptedInboxRig.snap([
              _enc('a'),
              conv('b', snippet: 'hi'),
              conv('c', snippet: 'x'),
              _enc('d'),
              conv('e', snippet: 'hi'),
            ]),
          );
      final c = cubit();

      await c.load();
      await pumpEventQueue();
      expect(port.asked, [
        ['a', 'c'],
      ], reason: 'one call for the page: the encrypted rows, no plaintext');

      await c.loadMore();
      await pumpEventQueue();
      expect(port.asked, [
        ['a', 'c'],
        ['d'],
      ], reason: 'the older page asks for its own encrypted rows only');
    });

    test('previewChanged refreshes one row', () async {
      rig.stub(network: [_enc('a'), _enc('b')]);
      final c = cubit();
      await c.load();
      await pumpEventQueue();
      port.asked.clear();

      port.setPreviews({
        'a': const ConversationPreview(kind: PreviewKind.text, text: 'new'),
      });
      await pumpEventQueue();

      expect(port.asked, [
        ['a'],
      ]);
      expect(c.state.previews['a']?.text, 'new');
      expect(c.state.previews.containsKey('b'), isFalse);

      // A conversation that is not loaded asks nothing.
      port.setPreviews({
        'zzz': const ConversationPreview(kind: PreviewKind.generic),
      });
      await pumpEventQueue();
      expect(port.asked, hasLength(1));
    });

    test('a failed previews call keeps placeholders and shows no '
        'error', () async {
      rig.stub(network: [_enc('a')]);
      port.failNextOn('previews', StateError('secret words'));
      final c = cubit();

      await c.load();
      await pumpEventQueue();

      expect(c.state.previews, isEmpty);
      expect(c.state.status, ConversationsStatus.ready);
      expect(c.state.error, isNull);
      expect(c.state.notice, isNull);
      expect(
        _line(c.state, c.state.conversations.single),
        kEncryptedPlaceholderText,
      );
      expect(reported, hasLength(1));
      expect(reported.single, isA<StateError>());
      expect((reported.single as StateError).message, 'previews');
      expect(port.asked, hasLength(1), reason: 'nothing is retried');
    });

    test('a request row is generic', () async {
      port.setPreviews({
        'r': const ConversationPreview(kind: PreviewKind.generic, mine: true),
      });
      rig.stub(folder: Folder.FOLDER_REQUESTS, network: [_enc('r')]);
      final c = cubit(folder: Folder.FOLDER_REQUESTS);

      await c.load();
      await pumpEventQueue();

      expect(c.state.previews['r']?.kind, PreviewKind.generic);
      expect(
        _line(c.state, c.state.conversations.single),
        kEncryptedPlaceholderText,
      );
    });

    test('a row the vault knows ignores a server snippet', () async {
      port.local = {'v'};
      port.setPreviews({
        'v': const ConversationPreview(
          kind: PreviewKind.text,
          text: 'vault words',
        ),
      });
      port.hold = Completer<void>();
      rig.stub(network: [conv('v', snippet: 'server words')]);
      final c = cubit();

      await c.load();
      final row = c.state.conversations.single;
      expect(row.lastMessage.encrypted, isFalse);
      expect(c.state.knownEncrypted, {'v'}, reason: 'in the same emit');
      expect(_line(c.state, row), kEncryptedPlaceholderText);

      port.hold!.complete();
      await pumpEventQueue();
      expect(_line(c.state, row), 'vault words');
    });

    test('no port, or no access: nothing is called and nothing is '
        'held', () async {
      rig.stub(network: [_enc('a')]);
      final none = cubit(withPort: false);
      await none.load();
      await pumpEventQueue();
      expect(none.state.previews, isEmpty);
      expect(none.state.knownEncrypted, isEmpty);

      final denied = cubit(allowed: () => false);
      await denied.load();
      port.setPreviews({
        'a': const ConversationPreview(kind: PreviewKind.generic),
      });
      await pumpEventQueue();
      expect(port.calls, isEmpty, reason: 'not hasLocal, not previews');
      expect(denied.state.previews, isEmpty);
    });

    test('a late answer after close, and a late event, are ignored', () async {
      rig.stub(network: [_enc('a')]);
      port.hold = Completer<void>();
      final c = cubit();
      await c.load();
      await pumpEventQueue();
      expect(port.asked, hasLength(1));

      await c.close();
      port.hold!.complete();
      port.setPreviews({
        'a': const ConversationPreview(kind: PreviewKind.generic),
      });
      await pumpEventQueue();

      expect(port.asked, hasLength(1), reason: 'the subscription is gone');
      expect(reported, isEmpty);
    });

    test('previews never survive a session reset', () async {
      port.setPreviews({
        'a': const ConversationPreview(kind: PreviewKind.text, text: _canary),
      });
      rig.stub(network: [_enc('a')]);
      final session = ConversationsSession(
        repository: rig.repo,
        encrypted: port,
        previewsAllowed: () => true,
      );
      addTearDown(session.dispose);
      final first = session.cubitFor(Folder.FOLDER_INBOX);
      await first.load();
      await pumpEventQueue();
      expect(first.state.previews['a']?.text, _canary);

      session.reset();
      await pumpEventQueue();

      expect(first.isClosed, isTrue);
      final next = session.cubitFor(Folder.FOLDER_INBOX);
      expect(next, isNot(same(first)));
      expect(next.state.previews, isEmpty);
    });

    test('the state holding previews is a plain class that prints no '
        'text', () async {
      port.setPreviews({
        'a': const ConversationPreview(kind: PreviewKind.text, text: _canary),
      });
      rig.stub(network: [_enc('a')]);
      final c = cubit();
      await c.load();
      await pumpEventQueue();

      expect(c.state.previews['a']?.text, _canary);
      expect(c.state.toString(), isNot(contains(_canary)));
      expect(c.state.toString(), startsWith('Instance of'));
      expect(c.state.previews['a'].toString(), startsWith('Instance of'));
    });
  });

  group('the screen', () {
    late EncryptedInboxRig rig;

    setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));

    pb.Conversation encrypted(String id) => _enc(id);

    testWidgets('no port: encrypted rows show the placeholder and nothing is '
        'called', (tester) async {
      rig = EncryptedInboxRig(withPort: false, withDevice: false);
      rig.stub(
        network: [
          encrypted('a'),
          conv('b', snippet: 'plain words'),
        ],
      );
      await rig.open(tester);

      expect(find.text(kEncryptedPlaceholderText), findsOneWidget);
      expect(find.text('plain words'), findsOneWidget);
      expect(rig.port.calls, isEmpty);
      expect(find.byType(EncryptionStatusBanner), findsNothing);
    });

    testWidgets('a row the vault knows ignores a server snippet', (
      tester,
    ) async {
      rig = EncryptedInboxRig();
      rig.port.local = {'v'};
      rig.stub(network: [conv('v', snippet: 'server words')]);
      await rig.open(tester);

      expect(find.text('server words'), findsNothing);
      expect(find.text(kEncryptedPlaceholderText), findsOneWidget);

      rig.port.setPreviews({
        'v': const ConversationPreview(
          kind: PreviewKind.text,
          text: 'vault words',
          mine: true,
        ),
      });
      await tester.pumpAndSettle();
      expect(find.text('You: vault words'), findsOneWidget);
      expect(find.text('server words'), findsNothing);
    });

    testWidgets('previews show per kind and the row semantics read them', (
      tester,
    ) async {
      rig = EncryptedInboxRig();
      rig.port.setPreviews({
        'a': const ConversationPreview(kind: PreviewKind.text, text: 'hello'),
        'b': const ConversationPreview(kind: PreviewKind.undecryptable),
      });
      rig.stub(network: [encrypted('a'), encrypted('b'), encrypted('c')]);
      await rig.open(tester);

      expect(find.text('hello'), findsOneWidget);
      expect(find.text(kCouldNotDecryptText), findsOneWidget);
      expect(find.text(kEncryptedPlaceholderText), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(ConversationRow).last).label,
        contains(kEncryptedPlaceholderText),
      );
    });

    group('the empty inbox note', () {
      Future<void> open(WidgetTester tester, EncryptedInboxRig r) async {
        rig = r;
        rig.stub();
        await rig.open(tester);
        expect(find.text('Welcome to your inbox'), findsOneWidget);
      }

      testWidgets('full: the mixed note', (tester) async {
        await open(tester, EncryptedInboxRig());
        expect(find.text(kEncryptionMixedNoteText), findsOneWidget);
        expect(find.byType(NotEncryptedNote), findsNothing);
      });

      testWidgets('manage: the mixed note', (tester) async {
        await open(tester, EncryptedInboxRig(flag: E2eeFlag.off));
        expect(find.text(kEncryptionMixedNoteText), findsOneWidget);
        expect(find.byType(NotEncryptedNote), findsNothing);
      });

      testWidgets('hidden: the old note, unchanged', (tester) async {
        await open(tester, EncryptedInboxRig(flag: E2eeFlag.off, vault: false));
        expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
        expect(find.byType(NotEncryptedNote), findsOneWidget);
        expect(find.text(kEncryptionMixedNoteText), findsNothing);
        expect(rig.port.calls, isEmpty);
      });

      testWidgets('unsupported: the old note, unchanged', (tester) async {
        await open(
          tester,
          EncryptedInboxRig(vaultStatus: VaultStatus.unsupported),
        );
        expect(find.byType(NotEncryptedNote), findsOneWidget);
        expect(find.text(kEncryptionMixedNoteText), findsNothing);
      });

      testWidgets('no device in the tree: the old note', (tester) async {
        await open(tester, EncryptedInboxRig(withDevice: false));
        expect(find.byType(NotEncryptedNote), findsOneWidget);
      });
    });

    group('flag x vault', () {
      for (final flag in E2eeFlag.values) {
        for (final vault in [true, false]) {
          testWidgets('flag ${flag.name}, vault on this device: $vault', (
            tester,
          ) async {
            rig = EncryptedInboxRig(flag: flag, vault: vault);
            rig.port.setPreviews({
              'a': const ConversationPreview(
                kind: PreviewKind.text,
                text: 'vault words',
              ),
            });
            rig.stub(
              network: [
                encrypted('a'),
                conv('b', snippet: 'plain'),
              ],
            );
            await rig.open(tester);

            final hidden = flag != E2eeFlag.on && !vault;
            expect(find.text('plain'), findsOneWidget);
            if (hidden) {
              expect(rig.port.calls, isEmpty, reason: 'no new call');
              expect(find.text('vault words'), findsNothing);
              expect(find.text(kEncryptedPlaceholderText), findsOneWidget);
              expect(rig.statusCubit!.state.kind, EncryptionStatusKind.none);
            } else {
              expect(rig.port.calls, contains('previews'));
              expect(find.text('vault words'), findsOneWidget);
            }
            expect(rig.reported, isEmpty);
          });
        }
      }
    });

    group('the status banner', () {
      testWidgets('shows for keyLostPending with Details', (tester) async {
        rig = EncryptedInboxRig(vaultStatus: VaultStatus.keyLost);
        rig.stub(network: [conv('a', snippet: 'still here')]);
        await rig.open(tester);

        final status = rig.statusCubit!.state;
        expect(status.kind, EncryptionStatusKind.keyLostPending);
        expect(
          find.text(
            encryptionStatusTitle(status) ?? encryptionStatusBody(status)!,
          ),
          findsOneWidget,
        );
        expect(find.text('still here'), findsOneWidget, reason: 'not replaced');
        expect(find.text(kStatusDetails), findsOneWidget);
        expect(find.text(kStatusDismiss), findsNothing);

        await tester.tap(find.text(kStatusDetails));
        await tester.pumpAndSettle();
        expect(rig.pushed, hasLength(1));
      });

      testWidgets('shows Dismiss for history lost, and Dismiss hides it', (
        tester,
      ) async {
        rig = EncryptedInboxRig(historyLost: true);
        rig.stub(network: [conv('a', snippet: 'still here')]);
        await rig.open(tester);

        expect(find.text(kStatusHistoryLostTitle), findsOneWidget);
        expect(find.text(kStatusDismiss), findsOneWidget);
        expect(find.text(kStatusDetails), findsNothing);

        await tester.tap(find.text(kStatusDismiss));
        await tester.pumpAndSettle();
        expect(find.text(kStatusHistoryLostTitle), findsNothing);
        expect(find.text('still here'), findsOneWidget);
      });

      testWidgets('no banner for kind none', (tester) async {
        rig = EncryptedInboxRig();
        rig.stub(network: [conv('a', snippet: 'still here')]);
        await rig.open(tester);

        expect(rig.statusCubit!.state.kind, EncryptionStatusKind.none);
        expect(find.text(kStatusDetails), findsNothing);
        expect(find.text(kStatusDismiss), findsNothing);
        // A zero-extent sliver counts as off stage for the finder.
        final banner = find.byType(EncryptionStatusBanner, skipOffstage: false);
        expect(tester.getSize(banner).height, 0);
      });

      testWidgets('the Requests folder has no banner', (tester) async {
        rig = EncryptedInboxRig(vaultStatus: VaultStatus.keyLost);
        rig.stub(
          folder: Folder.FOLDER_REQUESTS,
          network: [conv('a', snippet: 'a request')],
        );
        await rig.open(tester, folder: Folder.FOLDER_REQUESTS);

        expect(find.byType(EncryptionStatusBanner), findsNothing);
        expect(find.text(kStatusDetails), findsNothing);
      });

      testWidgets('no status cubit in the tree: nothing is drawn', (
        tester,
      ) async {
        rig = EncryptedInboxRig(
          vaultStatus: VaultStatus.keyLost,
          withStatusCubit: false,
        );
        rig.stub(network: [conv('a', snippet: 'still here')]);
        await rig.open(tester);

        expect(find.byType(EncryptionStatusBanner), findsNothing);
        expect(find.text('still here'), findsOneWidget);
      });
    });
  });

  group('the picker', () {
    Future<void> openPicker(
      WidgetTester tester, {
      required E2eeFlag flag,
      required bool vault,
      VaultStatus status = VaultStatus.ready,
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final onboarding = _MockOnboardingBloc();
      whenListen(
        onboarding,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          enabledFeatures: {
            'messaging',
            'graph',
            if (flag == E2eeFlag.on) kFeatureE2eeDm,
          },
          profile: identity.Profile(userId: 'u-me', handle: 'me'),
        ),
      );
      final device = FakeEncryptionDevice(
        status: status,
        vaultKnown: vault,
        flag: flag,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('home')),
          ),
          GoRoute(
            path: '/messages/new',
            pageBuilder: (context, state) => RecipientPickerPage(
              key: state.pageKey,
              source: FakePeopleSource(people: [person(1)]),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<MessagingRepository>.value(
              value: FakeSendRepository(),
            ),
            RepositoryProvider<IdentityRepository>.value(
              value: _MockIdentity(),
            ),
            RepositoryProvider<GraphRepository>.value(value: _MockGraph()),
            RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
            RepositoryProvider<EncryptionDevice>.value(value: device),
          ],
          child: BlocProvider<OnboardingBloc>.value(
            value: onboarding,
            child: MaterialApp.router(
              theme: appLightTheme,
              routerConfig: router,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(router.push('/messages/new'));
      await tester.pumpAndSettle();
    }

    testWidgets('the picker follows the same rule', (tester) async {
      await openPicker(tester, flag: E2eeFlag.on, vault: true);
      expect(find.text(kEncryptionMixedNoteText), findsOneWidget);
      expect(find.byType(NotEncryptedNote), findsNothing);
    });

    testWidgets('manage: the mixed note', (tester) async {
      await openPicker(tester, flag: E2eeFlag.off, vault: true);
      expect(find.text(kEncryptionMixedNoteText), findsOneWidget);
      expect(find.byType(NotEncryptedNote), findsNothing);
    });

    testWidgets('hidden: the old note, unchanged', (tester) async {
      await openPicker(tester, flag: E2eeFlag.unknown, vault: false);
      expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
      expect(find.byType(NotEncryptedNote), findsOneWidget);
      expect(find.text(kEncryptionMixedNoteText), findsNothing);
    });

    testWidgets('unsupported: the old note, unchanged', (tester) async {
      await openPicker(
        tester,
        flag: E2eeFlag.on,
        vault: false,
        status: VaultStatus.unsupported,
      );
      expect(find.byType(NotEncryptedNote), findsOneWidget);
      expect(find.text(kEncryptionMixedNoteText), findsNothing);
    });
  });
}
