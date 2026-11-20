import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/message_search.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_search_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_search_state.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encrypted_search_results.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_search_panel.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/encrypted_search_rig.dart';
import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_transport.dart';
import '../../../../support/messaging_fixtures.dart';

const _todayIdle =
    'Finds messages from conversations you have opened on this device.';
const _todayEmpty = 'Only messages cached on this device are searched.';

EncryptedSearchHit _hit(
  String conversationId,
  String messageId,
  String text, {
  int secondsAgo = 0,
  bool mine = false,
}) => EncryptedSearchHit(
  conversationId: conversationId,
  messageId: messageId,
  at: kMsgBase.subtract(Duration(seconds: secondsAgo)),
  mine: mine,
  text: text,
);

bool _yes() => true;

/// A port whose `search` answers only when the test says so, per query.
class _SlowPort extends FakeEncryptedMessaging {
  final Map<String, Completer<List<EncryptedSearchHit>>> pending = {};

  @override
  Future<List<EncryptedSearchHit>> search(
    String query, {
    String? conversationId,
    int limit = 200,
  }) {
    calls.add('search');
    searchQueries.add(query);
    return (pending[query] = Completer<List<EncryptedSearchHit>>()).future;
  }
}

MessageSearchCubit _cubit(
  EncryptedSearchRig rig, {
  String? conversationId,
  EncryptedMessaging? port,
  bool Function()? allowed = _yes,
  Duration debounce = Duration.zero,
}) {
  final cubit = MessageSearchCubit(
    repository: rig.repo,
    conversationId: conversationId,
    debounce: debounce,
    onUnexpectedError: (error, _) => rig.reported.add(error),
    encrypted: port ?? rig.port,
    encryptedAllowed: allowed,
  );
  addTearDown(cubit.close);
  return cubit;
}

Future<void> _ready(MessageSearchCubit cubit) =>
    cubit.stream.firstWhere((s) => s.status == MessageSearchStatus.ready);

Finder _row(String text) => find.byWidgetPredicate(
  (w) => w is HighlightedMatch && w.text == text,
  description: 'a result row of "$text"',
);

void main() {
  group('groupEncryptedHits', () {
    test('groupEncryptedHits puts a hit in its conversation\'s group with the '
        'right ranges', () {
      final groups = groupEncryptedHits(
        [conv('c1')],
        [_hit('c1', 'm1', 'Hello NEEDLE and needle')],
        'needle',
      );
      expect(groups.query, 'needle');
      expect(groups.groups, hasLength(1));
      final group = groups.groups.single;
      expect(group.conversation.id, 'c1');
      expect(group.hits.single.messageId, 'm1');
      expect(group.ranges, [
        [const SearchRange(6, 12), const SearchRange(17, 23)],
      ]);
    });

    test('a hit of a conversation that is not cached or cannot be replied to '
        'is dropped', () {
      final blocked = conv('c2')..canReply = false;
      final groups = groupEncryptedHits(
        [conv('c1'), blocked],
        [
          _hit('c1', 'm1', 'needle'),
          _hit('c2', 'm2', 'needle'),
          _hit('c9', 'm3', 'needle'),
        ],
        'needle',
      );
      expect(groups.groups.map((g) => g.conversation.id), ['c1']);
    });

    test('groups and hits stay newest first', () {
      final groups = groupEncryptedHits(
        [conv('c1'), conv('c2')],
        [
          _hit('c1', 'old', 'needle', secondsAgo: 300),
          _hit('c2', 'mid', 'needle', secondsAgo: 100),
          _hit('c1', 'new', 'needle', secondsAgo: 10),
        ],
        'needle',
      );
      expect(groups.groups.map((g) => g.conversation.id), ['c1', 'c2']);
      expect(groups.groups.first.hits.map((h) => h.messageId), ['new', 'old']);
    });
  });

  group('cubit', () {
    test('the port is asked once per debounced query with the conversation '
        'id', () async {
      final rig = EncryptedSearchRig(conversations: [conv('c1')]);
      rig.port.setSearchHits([_hit('c1', 'm1', 'a needle')]);
      final cubit = _cubit(
        rig,
        conversationId: 'c1',
        debounce: const Duration(milliseconds: 20),
      );
      cubit
        ..setQuery('n')
        ..setQuery('ne')
        ..setQuery('Needle');
      await _ready(cubit);
      expect(rig.port.searchQueries, ['Needle']);
      expect(rig.port.calls.where((c) => c == 'search'), hasLength(1));
      expect(cubit.encryptedResults.value.groups, hasLength(1));
      expect(cubit.encryptedResults.value.query, 'Needle');
    });

    test('no port: nothing is asked and results equal today\'s', () async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'plain needle')],
        },
      );
      rig.port.setSearchHits([_hit('c1', 'm1', 'vault needle')]);
      final today = MessageSearchCubit(
        repository: rig.repo,
        debounce: Duration.zero,
      );
      addTearDown(today.close);
      final withoutPort = MessageSearchCubit(
        repository: rig.repo,
        debounce: Duration.zero,
        encrypted: null,
      );
      addTearDown(withoutPort.close);
      // A port the access check refuses, and one with no check at all.
      final refused = _cubit(rig, allowed: () => false);
      final unchecked = _cubit(rig, allowed: null);

      final sequences = <List<MessageSearchStatus>>[];
      for (final cubit in [today, withoutPort, refused, unchecked]) {
        final seen = <MessageSearchStatus>[];
        final sub = cubit.stream.listen((s) => seen.add(s.status));
        cubit.setQuery('needle');
        await _ready(cubit);
        await pumpEventQueue();
        await sub.cancel();
        sequences.add(seen);
        expect(cubit.state.hitCount, 1);
        expect(
          cubit.state.groups.single.hits.single.message.text,
          'plain needle',
        );
        expect(cubit.encryptedResults.value.isEmpty, isTrue);
      }
      expect(sequences.map((s) => s.toString()).toSet(), hasLength(1));
      expect(rig.port.calls, isEmpty);
      expect(rig.port.searchQueries, isEmpty);
    });

    test('a late answer for an old query is dropped', () async {
      final slow = _SlowPort();
      final rig = EncryptedSearchRig(conversations: [conv('c1')], port: slow);
      final cubit = _cubit(rig, port: slow);

      cubit.setQuery('old');
      while (!slow.pending.containsKey('old')) {
        await pumpEventQueue();
      }
      cubit.setQuery('new');
      while (!slow.pending.containsKey('new')) {
        await pumpEventQueue();
      }
      slow.pending['new']!.complete([_hit('c1', 'mb', 'new answer')]);
      await _ready(cubit);
      slow.pending['old']!.complete([_hit('c1', 'ma', 'old answer')]);
      await pumpEventQueue();

      final groups = cubit.encryptedResults.value;
      expect(groups.query, 'new');
      expect(groups.groups.single.hits.map((h) => h.messageId), ['mb']);
    });

    test('a search in flight is abandoned when the cubit closes', () async {
      final slow = _SlowPort();
      final rig = EncryptedSearchRig(conversations: [conv('c1')], port: slow);
      final cubit = _cubit(rig, port: slow);
      cubit.setQuery('old');
      while (!slow.pending.containsKey('old')) {
        await pumpEventQueue();
      }
      await cubit.close();
      slow.pending['old']!.complete([_hit('c1', 'ma', 'late answer')]);
      await pumpEventQueue();
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
      expect(rig.reported, isEmpty);
    });

    test('a port failure keeps the cache results and reports without the '
        'query text', () async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'plain needle')],
        },
      );
      rig.port.failNextOn('search', StateError('boom needle-secret'));
      final cubit = _cubit(rig);
      cubit.setQuery('needle');
      await _ready(cubit);

      expect(cubit.state.hitCount, 1);
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
      expect(rig.reported, hasLength(1));
      final error = rig.reported.single;
      expect(error, isA<StateError>());
      expect((error as StateError).message, 'search');
      expect(error.toString(), isNot(contains('needle')));
    });

    test('canLoadOlder is false for an encrypted conversation', () async {
      for (final marker in ['hasLocal', 'header', 'lastMessage']) {
        final header = conv('c1');
        if (marker == 'header') {
          header.encryption =
              ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
        }
        if (marker == 'lastMessage') {
          header.lastMessage = pb.MessagePreview(encrypted: true);
        }
        final rig = EncryptedSearchRig(
          conversations: [header],
          messages: {
            'c1': [msg(1, text: 'plain needle')],
          },
        );
        when(() => rig.repo.olderSearchToken('c1'))
            .thenAnswer((_) async => 'tok');
        if (marker == 'hasLocal') rig.port.local = {'c1'};
        final cubit = _cubit(rig, conversationId: 'c1');
        cubit.setQuery('needle');
        await _ready(cubit);
        expect(cubit.state.canLoadOlder, isFalse, reason: marker);
      }
    });

    test('canLoadOlder stays as today for a plaintext conversation and with '
        'no usable port', () async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'plain needle')],
        },
      );
      when(() => rig.repo.olderSearchToken('c1'))
          .thenAnswer((_) async => 'tok');
      final plain = _cubit(rig, conversationId: 'c1');
      plain.setQuery('needle');
      await _ready(plain);
      expect(plain.state.canLoadOlder, isTrue);

      rig.port.local = {'c1'};
      final refused = _cubit(rig, conversationId: 'c1', allowed: () => false);
      refused.setQuery('needle');
      await _ready(refused);
      expect(refused.state.canLoadOlder, isTrue);
    });

    test('the results are cleared on a new query, on clear, on access loss and '
        'on close', () async {
      final rig = EncryptedSearchRig(conversations: [conv('c1')]);
      rig.port.setSearchHits([_hit('c1', 'm1', 'a needle')]);
      var allowed = true;
      final cubit = _cubit(rig, allowed: () => allowed);

      cubit.setQuery('needle');
      await _ready(cubit);
      expect(cubit.encryptedResults.value.groups, hasLength(1));

      // A new query: the old answer is gone at once, before the new one.
      cubit.setQuery('needles');
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
      await _ready(cubit);
      expect(cubit.encryptedResults.value.groups, hasLength(1));

      cubit.setQuery('');
      expect(cubit.encryptedResults.value.isEmpty, isTrue);

      cubit.setQuery('needle');
      await _ready(cubit);
      expect(cubit.encryptedResults.value.groups, hasLength(1));
      allowed = false;
      cubit.accessChanged();
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
      // With access lost no further search asks the port.
      final asked = rig.port.searchQueries.length;
      cubit.setQuery('needle again');
      await _ready(cubit);
      expect(rig.port.searchQueries, hasLength(asked));

      allowed = true;
      cubit.setQuery('needle');
      await _ready(cubit);
      expect(cubit.encryptedResults.value.groups, hasLength(1));
      await cubit.close();
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
    });

    test('accessChanged keeps the hits while access holds', () async {
      final rig = EncryptedSearchRig(conversations: [conv('c1')]);
      rig.port.setSearchHits([_hit('c1', 'm1', 'a needle')]);
      final cubit = _cubit(rig);
      cubit.setQuery('needle');
      await _ready(cubit);
      cubit.accessChanged();
      expect(cubit.encryptedResults.value.groups, hasLength(1));
    });

    test('an answer that arrives after access was lost is dropped', () async {
      final slow = _SlowPort();
      final rig = EncryptedSearchRig(conversations: [conv('c1')], port: slow);
      var allowed = true;
      final cubit = _cubit(rig, port: slow, allowed: () => allowed);
      cubit.setQuery('needle');
      while (!slow.pending.containsKey('needle')) {
        await pumpEventQueue();
      }
      allowed = false;
      slow.pending['needle']!.complete([_hit('c1', 'm1', 'a needle')]);
      await _ready(cubit);
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
    });

    test('the search state\'s toString holds no hit text', () async {
      const secret = 'zq-VAULT-ONLY-CANARY-77 NEEDLE tail';
      final rig = EncryptedSearchRig(conversations: [conv('c1')]);
      rig.port.setSearchHits([_hit('c1', 'm1', secret)]);
      final cubit = _cubit(rig);
      cubit.setQuery('needle');
      await _ready(cubit);

      expect(
        cubit.encryptedResults.value.groups.single.hits.single.text,
        secret,
      );
      final printed = cubit.state.toString();
      expect(printed, isNot(contains('CANARY')));
      expect(printed, isNot(contains(secret)));
      expect(cubit.state.groups, isEmpty);
      expect(cubit.state.hitCount, 0);
    });

    test('the encrypted types print nothing readable', () {
      const secret = 'zq-VAULT-ONLY-CANARY-77';
      final groups = groupEncryptedHits(
        [conv('c1')],
        [_hit('c1', 'm1', secret)],
        'canary',
      );
      for (final printed in [
        groups.toString(),
        groups.groups.single.toString(),
        groups.groups.single.hits.single.toString(),
      ]) {
        expect(printed, startsWith('Instance of '));
        expect(printed, isNot(contains('CANARY')));
      }
    });

    test('no pb.Message is built for an encrypted hit: nothing of a hit or the '
        'query reaches the store', () async {
      const canary = 'VAULT-CANARY-9f3';
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessagingStore(db);
      final procedures = <String>[];
      final api = ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          procedures.add(procedure);
          if (procedure == '/${MessagingService.name}/ListMessages') {
            return pb.ListMessagesResponse(
              messages: [msg(2, secondsAgo: 5, text: 'recent talk')],
              conversation: conv('c1'),
              sinceToken: 's',
            );
          }
          throw UnimplementedError(procedure);
        }),
      );
      final repository = MessagingRepository(
        apiClient: api,
        store: store,
        gate: MessagingFeatureGate(isMessagingEnabled: () => true),
        rateLimitHold: RateLimitHold(),
      );
      await repository.refreshThread('c1');
      final before = List.of(procedures);

      final port = FakeEncryptedMessaging()
        ..setSearchHits([_hit('c1', 'mv', 'text $canary here')]);
      final cubit = MessageSearchCubit(
        repository: repository,
        debounce: Duration.zero,
        encrypted: port,
        encryptedAllowed: _yes,
      );
      addTearDown(cubit.close);
      cubit.setQuery(canary.toLowerCase());
      await _ready(cubit);

      expect(cubit.encryptedResults.value.groups, hasLength(1));
      // No pb.Message for the hit: the state holds none.
      expect(cubit.state.groups, isEmpty);
      expect(cubit.state.hitCount, 0);
      // The repository was asked nothing new and the store holds no canary.
      expect(procedures, before);
      final corpus = await store.readSearchCorpus();
      expect(
        corpus.messages.toString().toLowerCase(),
        isNot(contains('canary')),
      );
      expect(
        corpus.conversations.toString().toLowerCase(),
        isNot(contains('canary')),
      );
      expect(corpus.messages['c1']!.map((m) => m.text), ['recent talk']);

      // Every row of every table of the database: no hit text, no query.
      final rows = <String>[];
      for (final table in db.allTables) {
        final read = await db
            .customSelect('SELECT * FROM ${table.actualTableName}')
            .get();
        for (final row in read) {
          rows.add(
            row.data.values
                .map((v) => v is List<int> ? String.fromCharCodes(v) : '$v')
                .join('|'),
          );
        }
      }
      expect(rows, isNotEmpty, reason: 'the scan reads real rows');
      for (final row in rows) {
        expect(row.toLowerCase(), isNot(contains('canary')));
      }
    });

    test('losing access while a search is pending makes no further port '
        'call', () async {
      final slow = _SlowPort()..local = {'c1'};
      final rig = EncryptedSearchRig(conversations: [conv('c1')], port: slow);
      var allowed = true;
      final cubit = _cubit(
        rig,
        port: slow,
        conversationId: 'c1',
        allowed: () => allowed,
      );
      cubit.setQuery('needle');
      while (!slow.pending.containsKey('needle')) {
        await pumpEventQueue();
      }
      allowed = false;
      slow.pending['needle']!.complete([_hit('c1', 'm1', 'a needle')]);
      await _ready(cubit);
      final after = slow.calls.sublist(slow.calls.indexOf('search') + 1);
      expect(after, isEmpty, reason: 'no port call once access was lost');
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
    });

    test('a failed search on an encrypted conversation offers no older '
        'pages', () async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'plain needle')],
        },
      );
      when(() => rig.repo.olderSearchToken('c1'))
          .thenAnswer((_) async => 'tok');
      rig.port.local = {'c1'};
      rig.port.failNextOn('search', StateError('x'));
      final cubit = _cubit(rig, conversationId: 'c1');
      cubit.setQuery('needle');
      await _ready(cubit);
      expect(cubit.state.canLoadOlder, isFalse);
      expect(rig.reported.single, isA<StateError>());
    });

    test('an older query\'s hits are dropped when the query changed before the '
        'debounce fired', () async {
      final slow = _SlowPort();
      final rig = EncryptedSearchRig(conversations: [conv('c1')], port: slow);
      final cubit = _cubit(
        rig,
        port: slow,
        debounce: const Duration(milliseconds: 30),
      );
      cubit.setQuery('old');
      while (!slow.pending.containsKey('old')) {
        await pumpEventQueue();
      }
      // Typing on: the new query's debounce has not fired yet.
      cubit.setQuery('new');
      slow.pending['old']!.complete([_hit('c1', 'ma', 'old answer')]);
      await pumpEventQueue();
      expect(cubit.state.query, 'new');
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
    });
  });

  group('panel', () {
    testWidgets('the panel shows a conversation found in both the cache and '
        'the vault as one group', (tester) async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, secondsAgo: 100, text: 'cache needle')],
        },
      );
      rig.port.setSearchHits([
        _hit('c1', 'mv', 'vault needle', secondsAgo: 10),
      ]);
      await rig.pump(tester);
      await rig.type(tester, 'needle');

      expect(find.text('Peer c1'), findsOneWidget);
      expect(_row('vault needle'), findsOneWidget);
      expect(_row('cache needle'), findsOneWidget);
      // Newest first inside the one group.
      expect(
        tester.getTopLeft(_row('vault needle')).dy,
        lessThan(tester.getTopLeft(_row('cache needle')).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('groups of the vault and of the cache are newest first', (
      tester,
    ) async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1'), conv('c2')],
        messages: {
          'c1': [
            msg(1, conversationId: 'c1', secondsAgo: 500, text: 'c1 needle'),
          ],
        },
      );
      rig.port.setSearchHits([_hit('c2', 'mv', 'c2 needle', secondsAgo: 10)]);
      await rig.pump(tester);
      await rig.type(tester, 'needle');
      expect(
        tester.getTopLeft(find.text('Peer c2')).dy,
        lessThan(tester.getTopLeft(find.text('Peer c1')).dy),
      );
    });

    testWidgets(
      'a vault-only hit shows and opens the chat at that message with '
      'no text of its own',
      (tester) async {
        final rig = EncryptedSearchRig(conversations: [conv('c1')]);
        rig.port.setSearchHits([_hit('c1', 'mv', 'vault needle')]);
        await rig.pump(tester);
        await rig.type(tester, 'needle');
        await tester.tap(_row('vault needle'));
        await tester.pumpAndSettle();
        expect(rig.opened, hasLength(1));
        final opened = rig.opened.single;
        expect(opened.conversation.id, 'c1');
        expect(opened.message.id, 'mv');
        // An id-only message: nothing decrypted is copied into a pb.Message.
        expect(opened.message.text, isEmpty);
        expect(opened.ranges, isEmpty);
      },
    );

    testWidgets('the subtitles switch with access', (tester) async {
      Future<void> check(
        EncryptedSearchRig rig, {
        required bool saved,
        required String label,
      }) async {
        // A fresh panel for each tree (the last one keeps its typed query).
        await tester.pumpWidget(const SizedBox());
        await rig.pump(tester);
        expect(
          find.text(saved ? kSearchSavedIdleSubtitle : _todayIdle),
          findsOneWidget,
          reason: label,
        );
        expect(
          find.text(saved ? _todayIdle : kSearchSavedIdleSubtitle),
          findsNothing,
          reason: label,
        );
        await rig.type(tester, 'zzz nothing');
        expect(
          find.text(saved ? kSearchSavedEmptySubtitle : _todayEmpty),
          findsOneWidget,
          reason: label,
        );
        expect(
          find.text(saved ? _todayEmpty : kSearchSavedEmptySubtitle),
          findsNothing,
          reason: label,
        );
      }

      await check(EncryptedSearchRig(), saved: true, label: 'full');
      await check(
        EncryptedSearchRig(flag: E2eeFlag.off),
        saved: true,
        label: 'manage',
      );
      await check(
        EncryptedSearchRig(flag: E2eeFlag.unknown),
        saved: true,
        label: 'manage, unknown flag',
      );
      await check(
        EncryptedSearchRig(flag: E2eeFlag.off, vault: false),
        saved: false,
        label: 'hidden',
      );
      await check(
        EncryptedSearchRig(vaultStatus: VaultStatus.unsupported),
        saved: false,
        label: 'unsupported',
      );
      await check(
        EncryptedSearchRig(withDevice: false),
        saved: false,
        label: 'no device',
      );
    });

    for (final flag in E2eeFlag.values) {
      for (final vault in [true, false]) {
        testWidgets('flag ${flag.name} x vault ${vault ? 'yes' : 'no'}: the '
            'vault is searched only with access', (tester) async {
          final rig = EncryptedSearchRig(
            flag: flag,
            vault: vault,
            conversations: [conv('c1')],
            messages: {
              'c1': [msg(1, text: 'cache needle')],
            },
          );
          rig.port.setSearchHits([_hit('c1', 'mv', 'vault needle')]);
          await rig.pump(tester);
          await rig.type(tester, 'needle');
          final access = flag == E2eeFlag.on || vault;
          expect(_row('cache needle'), findsOneWidget);
          expect(_row('vault needle'), access ? findsOneWidget : findsNothing);
          expect(rig.port.searchQueries, access ? ['needle'] : isEmpty);
          expect(rig.port.calls, access ? ['search'] : isEmpty);
        });
      }
    }

    testWidgets('a device with no port keeps today\'s subtitles', (
      tester,
    ) async {
      final rig = EncryptedSearchRig(withPort: false);
      await rig.pump(tester);
      expect(find.text(_todayIdle), findsOneWidget);
      expect(find.text(kSearchSavedIdleSubtitle), findsNothing);
      await rig.type(tester, 'zzz nothing');
      expect(find.text(_todayEmpty), findsOneWidget);
      expect(find.text(kSearchSavedEmptySubtitle), findsNothing);
    });

    testWidgets('no port in the tree: today\'s search', (tester) async {
      final rig = EncryptedSearchRig(
        withPort: false,
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'cache needle')],
        },
      );
      await rig.pump(tester);
      await rig.type(tester, 'needle');
      expect(_row('cache needle'), findsOneWidget);
      expect(rig.port.calls, isEmpty);
      expect(rig.reported, isEmpty);
    });

    testWidgets('hits vanish when access is lost', (tester) async {
      final rig = EncryptedSearchRig(
        vault: false,
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'cache needle')],
        },
      );
      rig.port.setSearchHits([_hit('c1', 'mv', 'vault needle')]);
      await rig.pump(tester);
      await rig.type(tester, 'needle');
      expect(_row('vault needle'), findsOneWidget);

      rig.setFlagOn(false);
      // One frame: the readable text is already gone from the tree.
      await tester.pump();
      expect(_row('vault needle'), findsNothing);
      await tester.pumpAndSettle();
      // And the cubit itself holds nothing readable any more.
      final cubit = BlocProvider.of<MessageSearchCubit>(
        tester.element(
          find.byType(BlocBuilder<MessageSearchCubit, MessageSearchState>),
        ),
      );
      expect(cubit.encryptedResults.value.isEmpty, isTrue);
      expect(_row('vault needle'), findsNothing);
      expect(_row('cache needle'), findsOneWidget);
      expect(find.text(kSearchSavedIdleSubtitle), findsNothing);

      // Typing on asks the port nothing more.
      final asked = rig.port.searchQueries.length;
      await rig.type(tester, 'needle x');
      await rig.type(tester, 'needle');
      expect(rig.port.searchQueries, hasLength(asked));
      expect(_row('vault needle'), findsNothing);
    });

    testWidgets('a port failure keeps the cache rows and shows no error text', (
      tester,
    ) async {
      final rig = EncryptedSearchRig(
        conversations: [conv('c1')],
        messages: {
          'c1': [msg(1, text: 'cache needle')],
        },
      );
      rig.port.failNextOn('search', StateError('secret-detail'));
      await rig.pump(tester);
      await rig.type(tester, 'needle');
      expect(_row('cache needle'), findsOneWidget);
      expect(find.textContaining('secret-detail'), findsNothing);
      expect(find.textContaining('Bad state'), findsNothing);
      expect((rig.reported.single as StateError).message, 'search');
    });

    testWidgets('a vault-only result is not the empty state', (tester) async {
      final rig = EncryptedSearchRig(conversations: [conv('c1')]);
      rig.port.setSearchHits([_hit('c1', 'mv', 'vault needle')]);
      await rig.pump(tester);
      await rig.type(tester, 'needle');
      expect(find.text('No messages found'), findsNothing);
    });

    testWidgets('no hit anywhere is the empty state', (tester) async {
      final rig = EncryptedSearchRig(conversations: [conv('c1')]);
      await rig.pump(tester);
      await rig.type(tester, 'needle');
      expect(find.text('No messages found'), findsOneWidget);
    });
  });
}
