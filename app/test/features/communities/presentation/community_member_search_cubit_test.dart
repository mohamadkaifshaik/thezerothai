import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/domain/communities_feature_flag.dart';
import 'package:dzeroth/features/communities/presentation/bloc/community_member_search_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

pb.CommunityMember _row(
  String id, {
  pb.CommunityRole role = pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
}) => pb.CommunityMember(
  role: role,
  user: graph.UserListItem(
    user: common.AuthorSnapshot(userId: id, handle: 'h$id'),
  ),
);

/// A search that records its calls and answers [answer] (or throws [error]).
class _Server {
  final calls = <(String, pb.CommunityMemberFilter)>[];
  List<pb.CommunityMember> answer = [_row('1'), _row('2')];
  AppException? error;
  Completer<void>? hold;

  Future<List<pb.CommunityMember>> call({
    required String prefix,
    required pb.CommunityMemberFilter filter,
  }) async {
    calls.add((prefix, filter));
    await hold?.future;
    final e = error;
    if (e != null) throw e;
    return answer;
  }
}

const _debounce = Duration(milliseconds: 300);

void main() {
  late _Server server;

  setUp(() => server = _Server());

  CommunityMemberSearchCubit build() =>
      CommunityMemberSearchCubit(search: server.call, debounce: _debounce);

  test('waits 300 ms after the last keystroke, then asks once with the '
      'lower-cased prefix', () {
    fakeAsync((async) {
      final cubit = build();
      cubit.textChanged('m');
      expect(cubit.state.status, MemberSearchStatus.idle);
      cubit.textChanged('@Mo');
      expect(cubit.state.status, MemberSearchStatus.loading);
      async.elapse(const Duration(milliseconds: 200));
      cubit.textChanged('@Mor');
      async.elapse(const Duration(milliseconds: 299));
      expect(server.calls, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      async.flushMicrotasks();
      expect(server.calls, [
        ('mor', pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED),
      ]);
      expect(cubit.state.status, MemberSearchStatus.ready);
      expect(cubit.state.results, hasLength(2));
      expect(cubit.state.active, isTrue);
      cubit.close();
    });
  });

  test('blank, one character and an invalid text send nothing', () {
    fakeAsync((async) {
      final cubit = build();
      for (final (raw, status) in [
        ('', MemberSearchStatus.idle),
        ('@', MemberSearchStatus.idle),
        ('a', MemberSearchStatus.idle),
        ('sana.n', MemberSearchStatus.invalid),
        ('a b', MemberSearchStatus.invalid),
      ]) {
        cubit.textChanged(raw);
        async.elapse(_debounce * 2);
        expect(cubit.state.status, status, reason: raw);
      }
      expect(server.calls, isEmpty);
      expect(cubit.state.active, isTrue); // invalid shows its hint
      cubit.textChanged('');
      expect(cubit.state.active, isFalse);
      cubit.close();
    });
  });

  test('the latest text wins over a slower earlier answer', () {
    fakeAsync((async) {
      final cubit = build();
      server.hold = Completer<void>();
      cubit.textChanged('mo');
      async.elapse(_debounce);
      server.answer = [_row('9')];
      final first = server.hold!;
      server.hold = null;
      cubit.textChanged('mor');
      async.elapse(_debounce);
      async.flushMicrotasks();
      expect(cubit.state.results.single.user.user.userId, '9');
      first.complete();
      async.flushMicrotasks();
      expect(cubit.state.results.single.user.user.userId, '9');
      cubit.close();
    });
  });

  test('scopes: Banned asks BANNED; Moderators asks JOINED and keeps the '
      'owner and moderators; a scope change asks at once', () {
    fakeAsync((async) {
      final cubit = build();
      server.answer = [
        _row('o', role: pb.CommunityRole.COMMUNITY_ROLE_OWNER),
        _row('m', role: pb.CommunityRole.COMMUNITY_ROLE_MODERATOR),
        _row('p'),
      ];
      cubit.textChanged('ab');
      async.elapse(_debounce);
      async.flushMicrotasks();
      expect(cubit.state.results, hasLength(3));

      cubit.setScope(MemberSearchScope.moderators);
      async.flushMicrotasks();
      expect(
        server.calls.last.$2,
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_JOINED,
      );
      expect(
        [for (final r in cubit.state.results) r.user.user.userId],
        ['o', 'm'],
      );

      cubit.setScope(MemberSearchScope.banned);
      async.flushMicrotasks();
      expect(
        server.calls.last.$2,
        pb.CommunityMemberFilter.COMMUNITY_MEMBER_FILTER_BANNED,
      );
      expect(server.calls, hasLength(3));
      cubit.close();
    });
  });

  test('FEATURE_DISABLED for community_member_search: unavailable for good, '
      'no further call', () {
    fakeAsync((async) {
      final cubit = build();
      server.error = const FeatureDisabledException(
        'off',
        feature: kFeatureCommunityMemberSearch,
      );
      cubit.textChanged('ab');
      async.elapse(_debounce);
      async.flushMicrotasks();
      expect(cubit.state.unavailable, isTrue);
      expect(cubit.state.active, isFalse);
      cubit.textChanged('abc');
      async.elapse(_debounce);
      async.flushMicrotasks();
      expect(server.calls, hasLength(1));
      cubit.close();
    });
  });

  blocTest<CommunityMemberSearchCubit, MemberSearchState>(
    'another failure is an error state that Retry clears',
    build: () {
      server.error = const RateLimitedException('slow down');
      return CommunityMemberSearchCubit(
        search: server.call,
        debounce: Duration.zero,
      );
    },
    act: (cubit) async {
      cubit.textChanged('ab');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      server.error = null;
      cubit.retry();
      await Future<void>.delayed(Duration.zero);
    },
    verify: (cubit) {
      expect(cubit.state.status, MemberSearchStatus.ready);
      expect(cubit.state.error, isNull);
      expect(server.calls, hasLength(2));
    },
  );

  test('removeUser and restore', () {
    fakeAsync((async) {
      final cubit = build();
      cubit.textChanged('ab');
      async.elapse(_debounce);
      async.flushMicrotasks();
      final removed = cubit.removeUser('1')!;
      expect([for (final r in cubit.state.results) r.user.user.userId], ['2']);
      cubit.restore(removed.$1, removed.$2);
      expect(
        [for (final r in cubit.state.results) r.user.user.userId],
        ['1', '2'],
      );
      expect(cubit.removeUser('nobody'), isNull);
      cubit.close();
    });
  });
}
