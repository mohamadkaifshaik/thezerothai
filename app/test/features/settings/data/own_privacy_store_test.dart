import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/settings/data/own_privacy_store.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockIdentity extends Mock implements IdentityRepository {}

void main() {
  late AppDatabase db;
  late _MockIdentity repo;
  late void Function(identity.GetMeResponse, int) listener;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = _MockIdentity();
    when(() => repo.addGetMeListener(any())).thenAnswer((i) {
      listener =
          i.positionalArguments.single
              as void Function(identity.GetMeResponse, int);
    });
  });
  tearDown(() => db.close());

  identity.GetMeResponse me({bool receipts = true}) => identity.GetMeResponse(
    profile: identity.Profile(userId: 'me', readReceipts: receipts),
  );

  test('every GetMe answer is recorded (0 extra RPCs)', () {
    final store = OwnPrivacyStore();
    feedOwnPrivacyStore(store, identityRepository: repo, database: db);
    listener(me(), db.sessionEpoch.value);
    expect(store.value?.readReceipts, isTrue);
    listener(me(receipts: false), db.sessionEpoch.value);
    expect(store.value?.readReceipts, isFalse);
  });

  test('an answer of an ended session is dropped', () {
    final store = OwnPrivacyStore();
    feedOwnPrivacyStore(store, identityRepository: repo, database: db);
    final epoch = db.sessionEpoch.value;
    db.sessionEpoch.end();
    listener(me(), epoch);
    expect(store.value, isNull);
  });

  test('nothing is recorded once the owner is gone', () {
    final store = OwnPrivacyStore();
    var live = true;
    feedOwnPrivacyStore(
      store,
      identityRepository: repo,
      database: db,
      isLive: () => live,
    );
    live = false;
    listener(me(), db.sessionEpoch.value);
    expect(store.value, isNull);
  });

  test('the listenable notifies on a change only', () {
    final store = OwnPrivacyStore();
    var calls = 0;
    store.listenable.addListener(() => calls++);
    store.record(identity.Profile(userId: 'me'));
    store.record(identity.Profile(userId: 'me'));
    expect(calls, 1);
    store.clear();
    expect(calls, 2);
    store.dispose();
  });
}
