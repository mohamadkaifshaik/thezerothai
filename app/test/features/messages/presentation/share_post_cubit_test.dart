import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/bloc/share_post_cubit.dart';
import 'package:dzeroth/features/messages/presentation/share_post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_send_repository.dart';

const _postId = '1234567890123456789';
const _url = 'https://dzeroth.com/post/$_postId';

common.AuthorSnapshot _peer(int i) =>
    common.AuthorSnapshot(userId: 'u$i', handle: 'user$i');

void main() {
  late FakeSendRepository repo;
  late SharePostCubit cubit;
  var unexpected = 0;

  SharePostCubit make({bool Function()? isEnabled}) => SharePostCubit(
    repository: repo,
    postId: _postId,
    url: _url,
    ownUserId: 'u-me',
    isEnabled: isEnabled,
    onUnexpectedError: (_, _) => unexpected++,
  );

  setUp(() {
    repo = FakeSendRepository();
    cubit = make();
    unexpected = 0;
  });
  tearDown(() => cubit.close());

  group('choosing', () {
    test('toggles people in the order chosen', () {
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2))
        ..toggle(_peer(1));
      expect(cubit.state.recipients.map((r) => r.peer.userId), ['u2']);
      cubit.toggle(_peer(3));
      expect(cubit.state.recipients.map((r) => r.peer.userId), ['u2', 'u3']);
    });

    test('at most $kSharePostMaxRecipients; a sixth only raises the hint', () {
      for (var i = 1; i <= kSharePostMaxRecipients; i++) {
        cubit.toggle(_peer(i));
      }
      cubit.toggle(_peer(9));
      expect(cubit.state.recipients, hasLength(kSharePostMaxRecipients));
      expect(cubit.state.limitHit, isTrue);
      // Any later change clears the hint; dropping one makes room again.
      cubit.toggle(_peer(1));
      expect(cubit.state.limitHit, isFalse);
      cubit.toggle(_peer(9));
      expect(cubit.state.isSelected('u9'), isTrue);
    });

    test('the caller cannot be chosen', () {
      cubit.toggle(common.AuthorSnapshot(userId: 'u-me', handle: 'me'));
      expect(cubit.state.recipients, isEmpty);
    });

    test('every row has its own key, made once', () {
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      final keys = cubit.state.recipients.map((r) => r.key).toList();
      expect(keys.toSet(), hasLength(2));
      cubit.toggle(_peer(3));
      expect(cubit.state.recipients.map((r) => r.key).take(2), keys);
    });

    test('Send is off with nobody chosen', () async {
      expect(cubit.state.canSend, isFalse);
      await cubit.send();
      expect(repo.sendKeys, isEmpty);
    });
  });

  group('sending', () {
    test('one SendMessage per person, in order, each with its key, the post '
        'id and the link as text (no caption)', () async {
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2))
        ..toggle(_peer(3));
      final keys = cubit.state.recipients.map((r) => r.key).toList();
      await cubit.send();

      expect(repo.sendRecipients, ['u1', 'u2', 'u3']);
      expect(repo.sendKeys, keys);
      expect(repo.sendSharedPostIds, [_postId, _postId, _postId]);
      expect(repo.sendTexts, [_url, _url, _url]);
      expect(
        cubit.state.recipients.map((r) => r.status),
        everyElement(ShareRowStatus.sent),
      );
      expect(cubit.state.allSent, isTrue);
      expect(cubit.state.started, isTrue);
    });

    test('a caption is the text, as one paragraph', () async {
      cubit
        ..toggle(_peer(1))
        ..setCaption('  look at this\n\nso good  ');
      await cubit.send();
      expect(repo.sendTexts, ['look at this so good']);
    });

    test('no send overlaps another', () async {
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      final gate = repo.sendGate = Completer<void>();
      final sending = cubit.send();
      await Future<void>.delayed(Duration.zero);
      expect(repo.sendKeys, hasLength(1));
      expect(cubit.state.recipients[0].status, ShareRowStatus.sending);
      expect(cubit.state.recipients[1].status, ShareRowStatus.idle);
      repo.sendGate = null;
      gate.complete();
      await sending;
      expect(repo.sendKeys, hasLength(2));
    });

    test('the rows are locked once Send was pressed', () async {
      cubit.toggle(_peer(1));
      await cubit.send();
      cubit
        ..toggle(_peer(2))
        ..setCaption('late');
      expect(cubit.state.recipients, hasLength(1));
      expect(cubit.state.caption, isEmpty);
    });

    test('a refused person does not stop the rest, and shows why', () async {
      repo.failures.addAll([const CannotMessageException()]);
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      await cubit.send();

      final rows = cubit.state.recipients;
      expect(rows[0].status, ShareRowStatus.failed);
      expect(rows[0].error, isA<CannotMessageException>());
      expect(rows[1].status, ShareRowStatus.sent);
      expect(cubit.state.endedBy, isNull);
      expect(cubit.state.allSent, isFalse);
      expect(sharePostRowReason(rows[0].error!), "Can't send");
    });

    for (final error in <AppException>[
      const NotFoundException('post not found'),
      const ProtectedAccountException(),
      const ValidationException('bad', field: 'shared_post_id'),
      const FeatureDisabledException('off', feature: kFeatureDmPostShare),
      const NetworkException('offline'),
    ]) {
      test('${error.runtimeType} ends the whole share: the rest are '
          '"Not sent"', () async {
        repo.failures.add(error);
        cubit
          ..toggle(_peer(1))
          ..toggle(_peer(2))
          ..toggle(_peer(3));
        await cubit.send();

        expect(repo.sendKeys, hasLength(1));
        final rows = cubit.state.recipients;
        expect(rows[0].status, ShareRowStatus.failed);
        expect(rows[1].status, ShareRowStatus.skipped);
        expect(rows[2].status, ShareRowStatus.skipped);
        expect(cubit.state.endedBy, same(error));
      });
    }

    test('a retry sends only what is not sent, with the same keys', () async {
      repo.failures.add(const NotFoundException('post not found'));
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      final keys = cubit.state.recipients.map((r) => r.key).toList();
      await cubit.send();
      expect(cubit.state.canSend, isTrue);

      await cubit.send();
      expect(repo.sendKeys, [keys[0], keys[0], keys[1]]);
      expect(cubit.state.allSent, isTrue);
      expect(cubit.state.endedBy, isNull);
    });

    test('a sent row is not sent again by a retry', () async {
      repo.failures
        ..add(const CannotMessageException())
        ..add(const LimitReachedException('limit', quota: 'dm_new_daily'));
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2))
        ..toggle(_peer(3));
      // u1 refused, u2 refused, u3 sent.
      await cubit.send();
      await cubit.send();
      expect(repo.sendRecipients, ['u1', 'u2', 'u3', 'u1', 'u2']);
    });

    test('with the flag off nothing is sent', () async {
      cubit = make(isEnabled: () => false)
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      await cubit.send();

      expect(repo.sendKeys, isEmpty);
      final rows = cubit.state.recipients;
      expect(rows.map((r) => r.status), everyElement(ShareRowStatus.skipped));
      expect(
        cubit.state.endedBy,
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureDmPostShare,
        ),
      );
    });

    test('an unexpected error is reported and only fails that row', () async {
      repo.failures.add(StateError('boom'));
      cubit
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      await cubit.send();

      expect(unexpected, 1);
      expect(cubit.state.recipients[0].status, ShareRowStatus.failed);
      expect(cubit.state.recipients[1].status, ShareRowStatus.sent);
    });
  });

  group('error copy', () {
    test('NOT_FOUND is about the post, not the conversation', () {
      expect(
        sharePostErrorMessage(const NotFoundException('post not found')),
        "This post isn't available anymore.",
      );
    });

    test('a protected post says only the author can send it', () {
      expect(
        sharePostErrorMessage(const ProtectedAccountException()),
        contains('Only the author'),
      );
    });

    test('the dm_post_share refusal is its own text', () {
      expect(
        sharePostErrorMessage(
          const FeatureDisabledException('x', feature: kFeatureDmPostShare),
        ),
        contains('Sending a post in a message'),
      );
    });

    test('anything else falls back to the messaging wording', () {
      expect(
        sharePostErrorMessage(const CannotMessageException()),
        CannotMessageException.userMessage,
      );
    });
  });
}
