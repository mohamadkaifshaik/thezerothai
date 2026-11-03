import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/communities/domain/community_role.dart';
import 'package:dzeroth/features/communities/presentation/bloc/community_moderation_cubit.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockCommunities extends Mock implements CommunitiesRepository {}

/// One idempotency key per (action, target), reused on a retry and
/// dropped once the action succeeded (rule 4).
void main() {
  late _MockCommunities communities;
  late CommunityModerationCubit cubit;
  final keys = <String>[];

  setUpAll(() {
    registerFallbackValue(pb.MemberRoleAction.MEMBER_ROLE_ACTION_BAN);
  });

  setUp(() {
    keys.clear();
    communities = _MockCommunities();
    cubit = CommunityModerationCubit(
      communityId: '77',
      communities: communities,
    );
  });

  tearDown(() => cubit.close());

  void stubHide({Object? error}) {
    when(
      () => communities.hidePost(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        postId: any(named: 'postId'),
      ),
    ).thenAnswer((i) async {
      keys.add(i.namedArguments[#idempotencyKey] as String);
      if (error != null) throw error;
    });
  }

  test('a retry after a failure reuses the key; success drops it', () async {
    stubHide(error: const NetworkException('offline'));
    expect(await cubit.hidePost('p1'), isA<NetworkException>());
    expect(await cubit.hidePost('p1'), isA<NetworkException>());
    expect(keys[0], keys[1]);

    stubHide();
    expect(await cubit.hidePost('p1'), isNull);
    expect(keys[2], keys[0]);
    expect(await cubit.hidePost('p1'), isNull);
    expect(keys[3], isNot(keys[0]));
  });

  test('another post gets another key', () async {
    stubHide();
    await cubit.hidePost('p1');
    await cubit.hidePost('p2');
    expect(keys[0], isNot(keys[1]));
  });

  test('busy is set during the call and cleared after', () async {
    stubHide();
    final seen = <bool>[];
    final sub = cubit.stream.listen((s) => seen.add(s.isBusy('p1')));
    await cubit.hidePost('p1');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, [true, false]);
  });

  test('setRole returns the role the server sent, not the action', () async {
    when(
      () => communities.setMemberRole(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: '77',
        userId: 'u1',
        action: any(named: 'action'),
      ),
    ).thenAnswer(
      (_) async => pb.SetMemberRoleResponse(
        role: pb.CommunityRole.COMMUNITY_ROLE_MEMBER,
        community: pb.Community(communityId: '77'),
      ),
    );
    final r = await cubit.setRole(
      'u1',
      pb.MemberRoleAction.MEMBER_ROLE_ACTION_MAKE_MODERATOR,
    );
    expect(r.error, isNull);
    expect(r.change!.role, CommunityRole.member);
  });

  test('setRole returns a typed failure', () async {
    when(
      () => communities.setMemberRole(
        idempotencyKey: any(named: 'idempotencyKey'),
        communityId: any(named: 'communityId'),
        userId: any(named: 'userId'),
        action: any(named: 'action'),
      ),
    ).thenThrow(CommunityForbiddenException(CommunityForbiddenReason.notOwner));
    final r = await cubit.setRole(
      'u1',
      pb.MemberRoleAction.MEMBER_ROLE_ACTION_MAKE_MODERATOR,
    );
    expect(r.change, isNull);
    expect(r.error, isA<CommunityForbiddenException>());
  });
}
