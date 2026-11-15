import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/compose_audience.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pbc;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';
import '../../../../support/posts_fixtures.dart';

class _MockPosts extends Mock implements PostsRepository {}

class _MockCommunities extends Mock implements CommunitiesRepository {}

/// What the server received.
typedef _Sent = ({
  String key,
  String text,
  ReplyPolicy policy,
  String community,
  List<String> media,
  List<String> pollChoices,
});

/// The main composer's submit scenarios that differ between the foreground
/// send (no sender) and the background send (the session's `PostSender`):
/// the same request must reach the server either way, and a failure must
/// offer the same way out (the composer's error, or the row's Retry).
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
  });

  final community = pbc.Community(
    communityId: '1000000000000000001',
    name: 'Alpha',
    memberCount: Int64(7),
    viewerRole: pbc.CommunityRole.COMMUNITY_ROLE_MEMBER,
    status: pbc.CommunityStatus.COMMUNITY_STATUS_ACTIVE,
  );

  for (final background in [false, true]) {
    final mode = background ? 'background' : 'foreground';

    group(mode, () {
      late _MockPosts posts;
      late _MockCommunities communities;
      late MockMediaRepository media;
      late PendingPostsCubit pending;
      late PostSender? sender;
      late ComposerCubit cubit;
      late AttachmentsCubit attachments;
      late List<_Sent> sent;
      late List<AppException?> script;

      setUp(() {
        posts = _MockPosts();
        communities = _MockCommunities();
        media = MockMediaRepository();
        pending = PendingPostsCubit();
        sent = [];
        script = [];
        sender = background
            ? PostSender(pending: pending, repository: posts)
            : null;
        when(() => posts.subFeatureEnabled(any())).thenReturn(true);
        when(() => communities.cachedMine).thenReturn(null);
        when(() => communities.myCommunities()).thenAnswer(
          (_) async =>
              MyCommunities(communities: [community], canCreate: false),
        );
        when(
          () => posts.createPost(
            idempotencyKey: any(named: 'idempotencyKey'),
            text: any(named: 'text'),
            replyToPostId: any(named: 'replyToPostId'),
            quoteOfPostId: any(named: 'quoteOfPostId'),
            mediaIds: any(named: 'mediaIds'),
            mediaAltTexts: any(named: 'mediaAltTexts'),
            replyPolicy: any(named: 'replyPolicy'),
            poll: any(named: 'poll'),
            communityId: any(named: 'communityId'),
            beaconId: any(named: 'beaconId'),
          ),
        ).thenAnswer((i) async {
          final poll = i.namedArguments[#poll] as DraftPoll?;
          sent.add((
            key: i.namedArguments[#idempotencyKey] as String,
            text: i.namedArguments[#text] as String,
            policy: i.namedArguments[#replyPolicy] as ReplyPolicy,
            community: i.namedArguments[#communityId] as String,
            media: i.namedArguments[#mediaIds] as List<String>,
            pollChoices: poll?.choices ?? const [],
          ));
          final failure = script.isEmpty ? null : script.removeAt(0);
          if (failure != null) throw failure;
          return postView(1);
        });
        attachments = AttachmentsCubit(
          picker: FakeImagePicker(),
          processor: FakeImageProcessor(),
          uploader: MediaUploader(repository: media),
        );
        cubit = ComposerCubit(
          postsRepository: posts,
          pending: pending,
          sender: sender,
          author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
          attachments: attachments,
          replyAudienceEnabled: true,
          pollsFlag: true,
          engagementOn: true,
          communitiesEnabled: true,
          communities: communities,
          mediaOn: true,
        );
      });

      tearDown(() async {
        await cubit.close();
        await sender?.dispose();
        await attachments.close();
        await pending.close();
      });

      Future<void> submit() async {
        await cubit.submit();
        await sender?.idle;
      }

      test('a poll reaches the server as typed', () async {
        cubit
          ..textChanged('which one?')
          ..pollAdded()
          ..pollChoiceChanged(0, 'red')
          ..pollChoiceChanged(1, 'blue');

        await submit();

        expect(sent.single.pollChoices, ['red', 'blue']);
        expect(sent.single.text, 'which one?');
      });

      test('the reply audience reaches the server', () async {
        cubit
          ..textChanged('followers only')
          ..replyAudienceChanged(ReplyAudience.following);

        await submit();

        expect(sent.single.policy, ReplyPolicy.REPLY_POLICY_FOLLOWING);
      });

      test('the community reaches the server', () async {
        await cubit.loadAudiences();
        cubit
          ..textChanged('to alpha')
          ..audienceChanged(community.composeAudience);

        await submit();

        expect(sent.single.community, '1000000000000000001');
      });

      test(
        'email not verified: a way out, then the same key succeeds',
        () async {
          script = [const EmailNotVerifiedException('verify')];
          cubit.textChanged('verify first');

          await submit();
          if (background) {
            final row = pending.state.single;
            expect(row.needsVerify, isTrue);
            expect(row.canRetry, isTrue);
            await sender!.retry(row.localId);
          } else {
            expect(cubit.state.error, isA<EmailNotVerifiedException>());
            await submit();
          }

          expect(sent, hasLength(2));
          expect(sent[0].key, sent[1].key);
        },
      );

      test('a photo upload failure: nothing is created, the retry reuses the '
          'finished work', () async {
        stubHappyUpload(media);
        var failPut = true;
        when(() => media.putObject(any(), any())).thenAnswer((_) async {
          if (failPut) {
            failPut = false;
            throw const NetworkException('offline');
          }
        });
        final picker = FakeImagePicker()..next = [imageBytes('a')];
        final withPhoto = AttachmentsCubit(
          picker: picker,
          processor: FakeImageProcessor(),
          uploader: MediaUploader(repository: media),
        );
        await withPhoto.pick();
        await Future<void>.delayed(Duration.zero);
        final c = ComposerCubit(
          postsRepository: posts,
          pending: pending,
          sender: sender,
          author: common.AuthorSnapshot(userId: 'me', handle: 'me'),
          attachments: withPhoto,
          mediaOn: true,
        )..textChanged('with a photo');
        addTearDown(c.close);
        addTearDown(withPhoto.close);

        await c.submit();
        await sender?.idle;
        expect(sent, isEmpty, reason: 'no CreatePost without the photo');
        if (background) {
          final row = pending.state.single;
          expect(row.status, PendingPostStatus.failed);
          await sender!.retry(row.localId);
        } else {
          expect(c.state.uploadFailed, isTrue);
          await c.submit();
        }

        expect(sent.single.media, ['m1']);
        verify(
          () => media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).called(1);
      });
    });
  }
}
