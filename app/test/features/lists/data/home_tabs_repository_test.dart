import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/lists/data/home_tabs_repository.dart';
import 'package:dzeroth/features/lists/domain/home_tab_entry.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/lists/v1/lists.pb.dart' as lists_pb;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

common.HomeTab wire(String id, [String title = '']) => common.HomeTab(
  kind: common.HomeTabKind.HOME_TAB_KIND_LIST,
  id: id,
  title: title,
);

HomeTabEntry entry(String id, [String title = '']) =>
    HomeTabEntry(kind: HomeTabKind.list, id: id, title: title);

List<String> ids(Iterable<HomeTabEntry> tabs) => [for (final t in tabs) t.id];

void main() {
  late SessionEpoch epoch;
  late HomeTabsRepository repo;
  late List<tl.SetHomeTabsRequest> sent;
  late Future<Object> Function(tl.SetHomeTabsRequest) answer;
  var enabled = true;
  var reported = 0;
  var n = 0;

  setUp(() {
    enabled = true;
    reported = 0;
    n = 0;
    sent = [];
    epoch = SessionEpoch();
    answer = (r) async => tl.SetHomeTabsResponse(tabs: r.tabs);
    repo = HomeTabsRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          final request = input as tl.SetHomeTabsRequest;
          sent.add(request);
          final r = await answer(request);
          if (r is Exception) throw r;
          return r;
        }),
      ),
      gate: ServiceFeatureGate(
        isEnabled: () => enabled,
        onUnexpectedError: (_, _) => reported++,
      ),
      epoch: epoch,
      uuid: null,
    );
    repo.adoptFromMe([wire('1', 'A'), wire('2', 'B')], epoch: epoch.value);
    n = sent.length;
  });

  test('GetMe tabs are adopted in order; unknown kinds are hidden', () {
    repo.adoptFromMe([
      wire('3', 'C'),
      common.HomeTab(id: '9'),
      common.HomeTab(
        kind: common.HomeTabKind.HOME_TAB_KIND_COMMUNITY,
        id: '5',
        title: 'Com',
      ),
    ], epoch: epoch.value);

    expect(repo.tabs.map((t) => t.key), ['list:3', 'community:5']);
  });

  test('a GetMe that started in an ended session is ignored', () {
    final old = epoch.value;
    epoch.end();

    repo.adoptFromMe([wire('7')], epoch: old);

    expect(repo.tabs, isEmpty);
  });

  test('reorder applies at once and sends one SetHomeTabs', () async {
    final seen = <List<String>>[];
    repo.changes.listen((t) => seen.add(ids(t)));

    final done = repo.reorder(0, 2);

    expect(ids(repo.tabs), ['2', '1']);
    await done;
    expect(sent, hasLength(1));
    expect(ids(sent.single.tabs.map((t) => entry(t.id))), ['2', '1']);
    expect(sent.single.idempotencyKey, isNotEmpty);
    expect(ids(repo.tabs), ['2', '1']);
    expect(seen.first, ['2', '1']);
  });

  test('a failed SetHomeTabs restores the old order and rethrows', () async {
    answer = (_) async => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
      metadata: {'limit': 'home_tabs'},
    );
    final changes = <List<String>>[];
    repo.changes.listen((t) => changes.add(ids(t)));

    await expectLater(
      repo.reorder(0, 2),
      throwsA(isA<LimitReachedException>()),
    );

    expect(ids(repo.tabs), ['1', '2']);
    expect(changes, [
      ['2', '1'],
      ['1', '2'],
    ]);
  });

  test('a retry of the same wish reuses the idempotency key', () async {
    var fail = true;
    answer = (r) async => fail
        ? connect.ConnectException(connect.Code.unavailable, 'blip')
        : tl.SetHomeTabsResponse(tabs: r.tabs);

    await expectLater(repo.unpin(HomeTabKind.list, '1'), throwsA(anything));
    fail = false;
    await repo.unpin(HomeTabKind.list, '1');

    expect(sent, hasLength(2));
    expect(sent[1].idempotencyKey, sent[0].idempotencyKey);
    await repo.unpin(HomeTabKind.list, '2');
    expect(sent[2].idempotencyKey, isNot(sent[0].idempotencyKey));
  });

  test('taps during a write coalesce into one follow-up', () async {
    final gate = Completer<void>();
    answer = (r) async {
      if (sent.length == 1) await gate.future;
      return tl.SetHomeTabsResponse(tabs: r.tabs);
    };

    final a = repo.unpin(HomeTabKind.list, '1');
    final b = repo.pin(HomeTabKind.list, '3');
    final c = repo.pin(HomeTabKind.list, '4');
    expect(ids(repo.tabs), ['2', '3', '4']);
    gate.complete();
    await Future.wait([a, b, c]);

    expect(sent, hasLength(2));
    expect(ids(sent[1].tabs.map((t) => entry(t.id))), ['2', '3', '4']);
    expect(ids(repo.tabs), ['2', '3', '4']);
  });

  test('server titles replace the optimistic ones; the label prefers the '
      'latest list header', () async {
    answer = (r) async => tl.SetHomeTabsResponse(
      tabs: [for (final t in r.tabs) wire(t.id, 'Server ${t.id}')],
    );
    await repo.pin(HomeTabKind.list, '3');
    expect(repo.tabs.last.title, 'Server 3');

    repo.noteListInfo(lists_pb.ListInfo(listId: '3', name: 'Renamed'));

    expect(repo.labelFor(repo.tabs.last), 'Renamed');
    expect(repo.labelFor(repo.tabs.first), 'Server 1');
    expect(repo.needsLabel(entry('9')), isTrue);
    expect(repo.needsLabel(repo.tabs.last), isFalse);
  });

  test('a sixth tab is refused locally with LIMIT_REACHED home_tabs', () async {
    for (final id in ['3', '4', '5']) {
      await repo.pin(HomeTabKind.list, id);
    }
    expect(repo.isFull, isTrue);
    final before = sent.length;

    await expectLater(
      repo.pin(HomeTabKind.list, '6'),
      throwsA(
        isA<LimitReachedException>().having(
          (e) => e.quota,
          'quota',
          'home_tabs',
        ),
      ),
    );
    expect(sent, hasLength(before));
  });

  test('a duplicate is refused locally as VALIDATION tabs', () async {
    await expectLater(
      repo.setTabs([entry('1'), entry('1')]),
      throwsA(isA<ValidationException>()),
    );
    expect(sent, isEmpty);
  });

  test('UNIMPLEMENTED rolls back, is not reported, and disables writes until '
      'the next GetMe', () async {
    answer = (_) async =>
        connect.ConnectException(connect.Code.unimplemented, 'nope');

    await expectLater(
      repo.unpin(HomeTabKind.list, '1'),
      throwsA(isA<FeatureDisabledException>()),
    );

    expect(ids(repo.tabs), ['1', '2']);
    expect(reported, 0);
    expect(repo.writeUnavailable, isTrue);
    final before = sent.length;
    await expectLater(
      repo.unpin(HomeTabKind.list, '1'),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(sent, hasLength(before));

    repo.adoptFromMe([wire('1')], epoch: epoch.value);
    expect(repo.writeUnavailable, isFalse);
  });

  test('lists off: LIST tabs are hidden and not written', () async {
    enabled = false;

    expect(repo.tabs, isEmpty);
    await expectLater(
      repo.setTabs([entry('1')]),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(sent, isEmpty);
    enabled = true;
    expect(ids(repo.tabs), ['1', '2']);
  });

  test('sign-out clears tabs and titles; a late answer is dropped', () async {
    final gate = Completer<void>();
    answer = (r) async {
      await gate.future;
      return tl.SetHomeTabsResponse(tabs: r.tabs);
    };
    repo.noteListInfo(lists_pb.ListInfo(listId: '1', name: 'Mine'));
    final pending = repo.unpin(HomeTabKind.list, '1');

    epoch.end();
    repo.clearSession();
    expect(repo.tabs, isEmpty);
    gate.complete();
    await pending;

    expect(repo.tabs, isEmpty);
    expect(repo.labelFor(entry('1')), '');
    repo.adoptFromMe([wire('1', 'A')], epoch: epoch.value);
    expect(ids(repo.tabs), ['1']);
  });

  test('clearSession emits the empty list even before the epoch ends', () {
    final seen = <List<String>>[];
    repo.changes.listen((t) => seen.add(ids(t)));

    repo.clearSession();

    expect(seen, [<String>[]]);
    expect(repo.tabs, isEmpty);
  });

  test('unpinning everything is sent with lists off', () async {
    enabled = false;

    await repo.setTabs(const []);

    expect(sent.single.tabs, isEmpty);
    enabled = true;
    expect(repo.tabs, isEmpty);
  });

  test(
    'a GetMe during a write does not clobber the optimistic order',
    () async {
      final gate = Completer<void>();
      answer = (r) async {
        await gate.future;
        return tl.SetHomeTabsResponse(tabs: r.tabs);
      };
      final pending = repo.reorder(0, 2);

      repo.adoptFromMe([wire('1', 'A'), wire('2', 'B')], epoch: epoch.value);
      expect(ids(repo.tabs), ['2', '1']);
      gate.complete();
      await pending;

      expect(ids(repo.tabs), ['2', '1']);
      expect(n, 0);
    },
  );
}
