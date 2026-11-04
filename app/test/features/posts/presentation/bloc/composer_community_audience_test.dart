import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/compose_audience.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pbc;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/posts_fixtures.dart';
import '../../../../support/scheduled_fixtures.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

pbc.Community _community(
  String id, {
  String? name,
  pbc.CommunityRole role = pbc.CommunityRole.COMMUNITY_ROLE_MEMBER,
  pbc.CommunityStatus status = pbc.CommunityStatus.COMMUNITY_STATUS_ACTIVE,
}) => pbc.Community(
  communityId: id,
  name: name ?? 'Community $id',
  memberCount: Int64(7),
  viewerRole: role,
  status: status,
);

MyCommunities _mine(List<pbc.Community> list) =>
    MyCommunities(communities: list, canCreate: false);

/// The composer's audience, what CreatePost carries,
/// the schedule exclusion, the key per community, the echo check, drafts.
void main() {
  setUpAll(() {
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  late _MockPostsRepository repo;
  late _MockCommunities communities;
  late PendingPostsCubit pending;
  final a = _community('1000000000000000001', name: 'Alpha');
  final b = _community('1000000000000000002', name: 'Beta');

  setUp(() {
    repo = _MockPostsRepository();
    communities = _MockCommunities();
    pending = PendingPostsCubit();
    when(() => repo.subFeatureEnabled(any())).thenReturn(true);
    when(() => communities.cachedMine).thenReturn(null);
    when(() => communities.myCommunities())
        .thenAnswer((_) async => _mine([a, b]));
  });

  tearDown(() => pending.close());

  ComposerCubit make({
    bool on = true,
    String quote = '',
    String preselect = '',
    ComposerDraft? draft,
    bool replyAudience = true,
  }) {
    final cubit = ComposerCubit(
      postsRepository: repo,
      pending: pending,
      author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
      quoteOfPostId: quote,
      communitiesEnabled: on,
      communities: communities,
      initialCommunityId: preselect,
      initialDraft: draft,
      replyAudienceEnabled: replyAudience,
      scheduleEnabled: true,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  ComposerDraft draftIn(String communityId) => ComposerDraft(
    id: 'd1',
    uid: 'me',
    text: 'saved text',
    createdAt: scheduledBase(),
    updatedAt: scheduledBase(),
    communityId: communityId,
  );

  void stubCreate({Object? error, bool withCommunity = true}) {
    when(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: any(named: 'replyPolicy'),
        communityId: any(named: 'communityId'),
      ),
    ).thenAnswer((i) async {
      if (error != null) throw error;
      final view = postView(1);
      final id = i.namedArguments[#communityId] as String;
      if (withCommunity && id.isNotEmpty) {
        view.post.community = pb.CommunityRef(id: id, name: 'x');
      }
      return view;
    });
  }

  ({String communityId, ReplyPolicy policy}) sent() {
    final captured = verify(
      () => repo.createPost(
        idempotencyKey: any(named: 'idempotencyKey'),
        text: any(named: 'text'),
        replyToPostId: any(named: 'replyToPostId'),
        quoteOfPostId: any(named: 'quoteOfPostId'),
        mediaIds: any(named: 'mediaIds'),
        mediaAltTexts: any(named: 'mediaAltTexts'),
        replyPolicy: captureAny(named: 'replyPolicy'),
        communityId: captureAny(named: 'communityId'),
      ),
    ).captured;
    clearInteractions(repo);
    return (
      policy: captured[0] as ReplyPolicy,
      communityId: captured[1] as String,
    );
  }

  group('offer', () {
    test(
      'the picker needs the flag, a root post or quote and a membership',
      () async {
        final cubit = make();
        expect(cubit.canChooseCommunity, isFalse, reason: 'not loaded yet');
        await cubit.loadAudiences();
        expect(cubit.canChooseCommunity, isTrue);
        expect(cubit.state.communityChoices.map((c) => c.name), [
          'Alpha',
          'Beta',
        ]);
        expect(make(quote: '1').canChooseCommunity, isFalse);
        final quoted = make(quote: '1');
        await quoted.loadAudiences();
        expect(quoted.canChooseCommunity, isTrue, reason: 'a quote may');
      },
    );

    test('flag off: no read and no pill', () async {
      final cubit = make(on: false);
      await cubit.loadAudiences();
      verifyNever(() => communities.myCommunities());
      expect(cubit.canChooseCommunity, isFalse);
    });

    test('no memberships: no pill', () async {
      when(() => communities.myCommunities())
          .thenAnswer((_) async => _mine([]));
      final cubit = make();
      await cubit.loadAudiences();
      expect(cubit.canChooseCommunity, isFalse);
    });

    test('banned and archived communities are not offered', () async {
      when(() => communities.myCommunities()).thenAnswer(
        (_) async => _mine([
          a,
          _community(
            '1000000000000000003',
            role: pbc.CommunityRole.COMMUNITY_ROLE_BANNED,
          ),
          _community(
            '1000000000000000004',
            status: pbc.CommunityStatus.COMMUNITY_STATUS_ARCHIVED,
          ),
        ]),
      );
      final cubit = make();
      await cubit.loadAudiences();
      expect(cubit.state.communityChoices.map((c) => c.name), ['Alpha']);
    });

    test('the session cache is read with 0 calls', () async {
      when(() => communities.cachedMine).thenReturn(_mine([a]));
      final cubit = make();
      await cubit.loadAudiences();
      verifyNever(() => communities.myCommunities());
      expect(cubit.state.communityChoices, hasLength(1));
    });

    test('a failed read leaves no picker and posts to everyone', () async {
      when(() => communities.myCommunities())
          .thenThrow(const NetworkException('offline'));
      final cubit = make();
      await cubit.loadAudiences();
      expect(cubit.canChooseCommunity, isFalse);
      expect(cubit.state.audienceNotice, isNull, reason: 'none was asked for');
    });

    test('the server answering FEATURE_DISABLED hides the picker', () async {
      final cubit = make();
      await cubit.loadAudiences();
      when(() => repo.subFeatureEnabled('communities')).thenReturn(false);
      expect(cubit.canChooseCommunity, isFalse);
    });
  });

  group('choosing', () {
    test('a keystroke keeps the audience', () async {
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(a.composeAudience);
      cubit.textChanged('hello');
      expect(cubit.state.audience, a.composeAudience);
      expect(cubit.state.communityChoices, hasLength(2));
    });

    test('only a community the caller is in can be chosen', () async {
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(
        const ComposeAudience.community(id: '9', name: 'Stranger'),
      );
      expect(cubit.state.audience, ComposeAudience.everyone);
    });

    test(
      'a community post takes no reply policy and hides the control',
      () async {
        stubCreate();
        final cubit = make();
        await cubit.loadAudiences();
        cubit.replyAudienceChanged(ReplyAudience.following);
        expect(cubit.canChooseReplyAudience, isTrue);
        cubit.audienceChanged(a.composeAudience);
        expect(cubit.canChooseReplyAudience, isFalse);
        cubit.textChanged('hi');
        await cubit.submit();
        final s = sent();
        expect(s.communityId, a.communityId);
        expect(s.policy, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
        // Back to Everyone brings the earlier choice back.
        cubit.audienceChanged(ComposeAudience.everyone);
        expect(cubit.canChooseReplyAudience, isTrue);
        expect(cubit.state.replyAudience, ReplyAudience.following);
      },
    );

    test('Everyone sends no community_id', () async {
      stubCreate();
      final cubit = make();
      await cubit.loadAudiences();
      cubit.textChanged('hi');
      await cubit.submit();
      expect(sent().communityId, '');
    });

    test('a quote may go into a community', () async {
      stubCreate();
      final cubit = make(quote: '2000000000000000001');
      await cubit.loadAudiences();
      cubit.audienceChanged(b.composeAudience);
      cubit.textChanged('q');
      await cubit.submit();
      expect(sent().communityId, b.communityId);
    });
  });

  group('schedule', () {
    test('a community blocks Schedule with a reason', () async {
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(a.composeAudience);
      expect(cubit.rules.schedule.scheduleTooltip, contains('Community'));
      cubit.scheduleChanged(scheduledBase().add(const Duration(days: 2)));
      expect(cubit.state.scheduledAt, isNull);
    });

    test('a schedule time hides the picker and refuses a community', () async {
      final cubit = make();
      await cubit.loadAudiences();
      cubit.scheduleChanged(scheduledBase().add(const Duration(days: 2)));
      expect(cubit.state.isScheduling, isTrue);
      expect(cubit.canChooseCommunity, isFalse);
      cubit.audienceChanged(a.composeAudience);
      expect(cubit.state.audience, ComposeAudience.everyone);
    });
  });

  group('idempotency key', () {
    test('differs per community and returns for the same one', () async {
      stubCreate(error: const NetworkException('offline'));
      final cubit = make();
      await cubit.loadAudiences();
      cubit.textChanged('same words');
      await cubit.submit();
      final plain = cubit.currentKey;
      cubit.audienceChanged(a.composeAudience);
      await cubit.submit();
      final inA = cubit.currentKey;
      cubit.audienceChanged(b.composeAudience);
      await cubit.submit();
      final inB = cubit.currentKey;
      expect({plain, inA, inB}, hasLength(3));
      cubit.audienceChanged(a.composeAudience);
      await cubit.submit();
      expect(cubit.currentKey, inA);
    });
  });

  group('after the answer', () {
    test('echo check: a post without its community is flagged', () async {
      stubCreate(withCommunity: false);
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(a.composeAudience);
      cubit.textChanged('hi');
      await cubit.submit();
      expect(cubit.state.status, ComposerStatus.posted);
      expect(cubit.state.communityNotApplied, isTrue);
    });

    test('a post that came back labelled is not flagged', () async {
      stubCreate();
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(a.composeAudience);
      cubit.textChanged('hi');
      await cubit.submit();
      expect(cubit.state.communityNotApplied, isFalse);
      expect(
        cubit.state.created!.post.community.id,
        a.communityId,
        reason: 'the label is on the post the screen gets back',
      );
    });

    test(
      'not a member: back to Everyone, gone from the picker and cache',
      () async {
        stubCreate(
          error: CommunityForbiddenException(
            CommunityForbiddenReason.notMember,
          ),
        );
        final cubit = make();
        await cubit.loadAudiences();
        cubit.audienceChanged(a.composeAudience);
        cubit.textChanged('hi');
        await cubit.submit();
        expect(cubit.state.audience, ComposeAudience.everyone);
        expect(cubit.state.communityChoices.map((c) => c.name), ['Beta']);
        expect(cubit.state.error, isA<CommunityForbiddenException>());
        expect(cubit.state.draft.text, 'hi', reason: 'the text stays');
        verify(() => communities.forgetCommunity(a.communityId)).called(1);
      },
    );

    test('banned: the same', () async {
      stubCreate(
        error: CommunityForbiddenException(CommunityForbiddenReason.banned),
      );
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(b.composeAudience);
      cubit.textChanged('hi');
      await cubit.submit();
      expect(cubit.state.audience, ComposeAudience.everyone);
      verify(() => communities.forgetCommunity(b.communityId)).called(1);
    });

    test('a quota refusal keeps the community for the retry', () async {
      stubCreate(
        error: const QuotaExceededException('x', quota: 'community_posts'),
      );
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(a.composeAudience);
      cubit.textChanged('hi');
      await cubit.submit();
      expect(cubit.state.audience, a.composeAudience);
      verifyNever(() => communities.forgetCommunity(any()));
    });

    test('a protected account falls back to Everyone', () async {
      stubCreate(error: const ProtectedAccountException());
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(a.composeAudience);
      cubit.textChanged('hi');
      await cubit.submit();
      expect(cubit.state.audience, ComposeAudience.everyone);
      verifyNever(() => communities.forgetCommunity(any()));
    });
  });

  group('drafts (ADR-0029 F8)', () {
    test('a draft in a community the caller is in reopens on it', () async {
      final cubit = make(draft: draftIn(a.communityId));
      expect(cubit.state.audience, ComposeAudience.everyone, reason: 'unknown');
      expect(cubit.currentDraft.communityId, a.communityId, reason: 'kept');
      await cubit.loadAudiences();
      expect(cubit.state.audience, a.composeAudience);
      expect(cubit.state.audienceNotice, isNull);
    });

    test(
      'a community the caller left resets to Everyone and says so once',
      () async {
        final cubit = make(draft: draftIn('1000000000000000099'));
        await cubit.loadAudiences();
        expect(cubit.state.audience, ComposeAudience.everyone);
        expect(cubit.state.audienceNotice, AudienceNotice.notAMember);
        expect(cubit.currentDraft.communityId, '');
        expect(cubit.hasUnsavedDraftChanges, isFalse);
        cubit.audienceNoticeShown();
        expect(cubit.state.audienceNotice, isNull);
      },
    );

    test(
      'a failed read keeps the draft id and says it could not check',
      () async {
        when(() => communities.myCommunities())
            .thenThrow(const NetworkException('offline'));
        final cubit = make(draft: draftIn(a.communityId));
        await cubit.loadAudiences();
        expect(cubit.state.audience, ComposeAudience.everyone);
        expect(cubit.state.audienceNotice, AudienceNotice.couldNotLoad);
        expect(cubit.currentDraft.communityId, a.communityId);
      },
    );

    test('the chosen community is what the draft keeps', () async {
      final cubit = make();
      await cubit.loadAudiences();
      cubit.audienceChanged(b.composeAudience);
      expect(cubit.currentDraft.communityId, b.communityId);
      cubit.audienceChanged(ComposeAudience.everyone);
      expect(cubit.currentDraft.communityId, '');
    });
  });

  group('preselect from the community page', () {
    test(
      'a community the caller is in is chosen once the list loads',
      () async {
        final cubit = make(preselect: b.communityId);
        await cubit.loadAudiences();
        expect(cubit.state.audience, b.composeAudience);
      },
    );

    test(
      'a community the caller is not in opens on Everyone with a notice',
      () async {
        final cubit = make(preselect: '1000000000000000099');
        await cubit.loadAudiences();
        expect(cubit.state.audience, ComposeAudience.everyone);
        expect(cubit.state.audienceNotice, AudienceNotice.notAMember);
      },
    );
  });
}
