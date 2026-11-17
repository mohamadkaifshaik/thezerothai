import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:dzeroth/core/feature_flags/public_ids_feature_flag.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/session/public_id_transition.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/beacons/domain/plan_quick_start.dart'
    show kPlanFormMemoryKey;
import 'package:dzeroth/features/graph/data/suggestions_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/search/data/recent_searches_store.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_transport.dart';

const _getMe = '/dzeroth.identity.v1.IdentityService/GetMe';
const _uid = 'q7Zk3mV9aXb2LcD8eF1gH4iJ5kL6';

/// The wipe when `public_ids` appears in or disappears from the flag set:
/// once per transition and per account, never on a relaunch; it clears only
/// what holds ids of the wrong kind and keeps the user's own content.
void main() {
  late AppDatabase db;
  late int wipes;
  late List<Object> errors;
  late PublicIdTransition transition;
  Future<void> Function() wipeBody = () async {};

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    wipes = 0;
    errors = [];
    wipeBody = () async => db.clearIdBearingCache();
    transition = PublicIdTransition(
      database: db,
      wipe: () async {
        wipes++;
        await wipeBody();
      },
      onError: (e, _) => errors.add(e),
    );
    await db.claimCacheFor(_uid);
  });

  tearDown(() async {
    await transition.dispose();
    await db.close();
  });

  Future<int?> see(Set<String> flags) =>
      transition.onFlagSet(flags, db.sessionEpoch.value);
  const on = {'graph', kFeaturePublicIds};
  const off = {'graph'};

  Future<String?> marker() => db.readSetting(kPublicIdsSeenKey);

  test('a freshly claimed cache holds nothing id-bearing: the first flag set, '
      'on or off, is not a transition', () async {
    expect(await marker(), '-');
    expect(await see(on), isNull);
    expect(wipes, 0);
    expect(await marker(), '1');

    await db.claimCacheFor('another-account');
    expect(await marker(), '-');
    expect(await see(off), isNull);
    expect(wipes, 0);
    expect(await marker(), '0');
  });

  test('a cache from before the marker was filled with the flag off', () async {
    await db.deleteSetting(kPublicIdsSeenKey);
    expect(await see(off), isNull);
    expect(wipes, 0);
    expect(await marker(), '0');

    await db.deleteSetting(kPublicIdsSeenKey);
    expect(await see(on), isNotNull);
    expect(wipes, 1);
    expect(await marker(), '1');
  });

  test('off to on wipes once; the same flag set again, and every relaunch, '
      'does not', () async {
    await see(off);
    expect(await see(on), isNotNull);
    expect(wipes, 1);
    expect(await see(on), isNull);
    expect(await see(on), isNull);
    expect(wipes, 1);
    expect(await marker(), '1');
  });

  test('on to off (rollback) wipes once, then off to on wipes again', () async {
    await see(on);
    expect(await see(off), isNotNull);
    expect(wipes, 1);
    expect(await marker(), '0');
    expect(await see(off), isNull);
    expect(await see(on), isNotNull);
    expect(wipes, 2);
  });

  test('per account: another account starts from its own marker', () async {
    await see(on);
    await db.claimCacheFor('another-account');
    expect(await see(off), isNull, reason: 'a new cache, not a transition');
    expect(wipes, 0);
  });

  test(
    'a wipe invalidates earlier writes without ending the session',
    () async {
      await see(off);
      final before = db.sessionEpoch.value;
      var ended = 0;
      final sub = db.sessionEpoch.ended.listen((_) => ended++);
      addTearDown(sub.cancel);

      final fresh = await see(on);

      expect(fresh, db.sessionEpoch.value);
      expect(db.sessionEpoch.allows(before), isFalse);
      expect(db.sessionEpoch.allows(fresh!), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(ended, 0, reason: 'the composer and the post sender stay');
    },
  );

  test('announces a wipe to the holders of in-memory state', () async {
    await see(off);
    var announced = 0;
    final sub = transition.wiped.listen((_) => announced++);
    addTearDown(sub.cancel);

    await see(on);
    await see(on);

    expect(announced, 1);
  });

  test('an answer of a session that already ended changes nothing', () async {
    await see(off);
    final stale = db.sessionEpoch.value;
    db.sessionEpoch.end();

    expect(await transition.onFlagSet(on, stale), isNull);

    expect(wipes, 0);
    expect(await marker(), '0');
  });

  test('a failing wipe is reported, the marker stays, the next GetMe '
      'tries again', () async {
    await see(off);
    wipeBody = () async => throw StateError('disk');

    expect(await see(on), isNull);

    expect(errors, hasLength(1));
    expect(await marker(), '0');
    wipeBody = () async => db.clearIdBearingCache();
    expect(await see(on), isNotNull);
    expect(await marker(), '1');
  });

  group('what the wipe clears and keeps', () {
    Future<void> seed() async {
      final epoch = db.sessionEpoch.value;
      await db.upsertProfile(
        ProfileCacheEntriesCompanion.insert(
          userId: _uid,
          handle: 'me',
          displayName: 'Me',
          cachedAt: DateTime.now(),
        ),
        epoch: epoch,
      );
      await db.upsertFollowing('someone', epoch: epoch);
      await db
          .into(db.timelineItemEntries)
          .insert(
            TimelineItemEntriesCompanion.insert(
              feedKey: 'home',
              itemKey: '1',
              sortKey: '1',
            ),
          );
      await db
          .into(db.timelineStateEntries)
          .insert(
            TimelineStateEntriesCompanion.insert(
              feedKey: 'home',
              updatedAt: DateTime.now(),
              sinceToken: const Value('s'),
            ),
          );
      await db
          .into(db.notificationEntries)
          .insert(
            NotificationEntriesCompanion.insert(
              itemKey: 'n1_FOLLOW_$_uid',
              sortKey: '1',
            ),
          );
      await db
          .into(db.notificationStateEntries)
          .insert(
            NotificationStateEntriesCompanion.insert(
              stateKey: 'main',
              updatedAt: DateTime.now(),
              sinceToken: const Value('since'),
              olderPageToken: const Value('older'),
              seenAtMicros: const Value(77),
              deviceId: const Value('device-1'),
            ),
          );
      await db
          .into(db.conversationEntries)
          .insert(
            ConversationEntriesCompanion.insert(
              conversationId: 'c1',
              folder: 1,
              sortKey: '1',
              payload: Uint8List(0),
            ),
          );
      await db
          .into(db.messageEntries)
          .insert(
            MessageEntriesCompanion.insert(
              conversationId: 'c1',
              messageId: 'm1',
              sortKey: '1',
              payload: Uint8List(0),
            ),
          );
      await db
          .into(db.messagingStateEntries)
          .insert(
            MessagingStateEntriesCompanion.insert(
              stateKey: 'inbox',
              updatedAt: DateTime.now(),
            ),
          );
      await db.writeSetting(SuggestionsRepository.key(_uid), '[]');
      // The user's own content and device facts.
      await db
          .into(db.composerDraftEntries)
          .insert(
            ComposerDraftEntriesCompanion.insert(
              draftId: 'd1',
              uid: _uid,
              draftText: 'my unfinished post',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
      await db
          .into(db.unsentPostEntries)
          .insert(
            UnsentPostEntriesCompanion.insert(
              uid: _uid,
              postId: 'p1',
              authorBytes: Uint8List(0),
              createdAt: DateTime.now(),
            ),
          );
      await db
          .into(db.postHistoryEntries)
          .insert(
            PostHistoryEntriesCompanion.insert(
              uid: _uid,
              postId: 'p9',
              openedAtMs: 1,
            ),
          );
      await db.writeSetting(DatabaseRecentSearchesStore.key(_uid), '["cats"]');
      await db.writeSetting(kPlanFormMemoryKey, '{}');
      await db.writeSetting('theme_mode', 'dark');
    }

    Future<int> count(dynamic table) async =>
        (await db.select(table).get()).length;

    test(
      'clears id-bearing rows; keeps drafts, unsent posts and content',
      () async {
        await see(off);
        await seed();

        await see(on);

        expect(await db.profileByUserId(_uid), isNull);
        expect(await db.cachedFollowingIds(), isEmpty);
        expect(await count(db.timelineItemEntries), 0);
        expect(await count(db.timelineStateEntries), 0);
        expect(await count(db.notificationEntries), 0);
        expect(await count(db.conversationEntries), 0);
        expect(await count(db.messageEntries), 0);
        expect(await count(db.messagingStateEntries), 0);
        expect(await db.readSetting(SuggestionsRepository.key(_uid)), isNull);

        final state =
            (await db.select(db.notificationStateEntries).get()).single;
        expect(state.sinceToken, '');
        expect(state.olderPageToken, '');
        expect(state.seenAtMicros, 77);
        expect(state.deviceId, 'device-1', reason: 'no second push device');

        expect(await count(db.composerDraftEntries), 1);
        expect(await count(db.unsentPostEntries), 1);
        expect(await count(db.postHistoryEntries), 1);
        expect(
          await db.readSetting(DatabaseRecentSearchesStore.key(_uid)),
          '["cats"]',
        );
        expect(await db.readSetting(kPlanFormMemoryKey), '{}');
        expect(await db.readSetting('theme_mode'), 'dark');
        expect(await db.readSetting(kCacheOwnerKey), _uid);
      },
    );

    test('a relaunch with the same flag set leaves everything', () async {
      await see(on);
      await seed();

      await see(on);

      expect(await db.profileByUserId(_uid), isNotNull);
      expect(await count(db.timelineItemEntries), 1);
    });
  });

  test('GetMe: the flipped answer is cached after the wipe, under the new '
      'epoch, and the cache wiped is the old one', () async {
    final epoch = db.sessionEpoch.value;
    await db.upsertProfile(
      ProfileCacheEntriesCompanion.insert(
        userId: _uid,
        handle: 'old',
        displayName: 'Old',
        cachedAt: DateTime.now(),
      ),
      epoch: epoch,
    );
    await see(off);
    final repo = IdentityRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          expect(procedure, _getMe);
          return identity.GetMeResponse(
            profile: identity.Profile(
              userId: 'u0abcdefghijklmnopqrstuvw2',
              handle: 'me',
              displayName: 'Me',
            ),
            enabledFeatures: const [kFeaturePublicIds],
          );
        }),
      ),
      database: db,
    )..flagSetHook = transition.onFlagSet;

    final response = await repo.getMe();

    expect(wipes, 1);
    expect(response.profile.userId, 'u0abcdefghijklmnopqrstuvw2');
    expect(await db.profileByUserId(_uid), isNull, reason: 'old kind gone');
    expect(
      await db.profileByUserId('u0abcdefghijklmnopqrstuvw2'),
      isNotNull,
      reason: 'the answer itself is cached under the new epoch',
    );
  });
}
