import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/bloc/share_post_cubit.dart';
import 'package:dzeroth/features/messages/presentation/share_post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_send_repository.dart';

const _postId = '1234567890123456789';
const _url = 'https://dzeroth.com/post/$_postId';

common.AuthorSnapshot _peer(int i) =>
    common.AuthorSnapshot(userId: 'u$i', handle: 'user$i');

/// A share check that passes and shares the post as asked.
Future<String> _passes(String id) async => id;

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

  group('with an encrypted port', () {
    late FakeEncryptedMessaging port;

    SharePostCubit withPort({bool Function()? isEnabled}) => SharePostCubit(
      repository: repo,
      postId: _postId,
      url: _url,
      ownUserId: 'u-me',
      isEnabled: isEnabled,
      encrypted: port,
      check: _passes,
      checkEnabled: () => true,
      onUnexpectedError: (_, _) => unexpected++,
    );

    setUp(() => port = FakeEncryptedMessaging());
    tearDown(() => port.dispose());

    test('with a port, a queued share is sent and sendMessage is not called '
        'for it', () async {
      final c = withPort()..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expect(c.state.recipients.single.status, ShareRowStatus.sent);
      expect(port.sent.single.to, ThreadRef.recipientOf(_peer(1)));
      expect(port.sent.single.text, _url);
      expect(port.sent.single.sharedPostId, _postId);
      expect(repo.sendKeys, isEmpty);
    });

    test('a recipient row stays in its existing sending state while the '
        'port\'s send is pending', () async {
      final hold = Completer<void>();
      port.holdSend = hold;
      final c = withPort()..toggle(_peer(1));
      addTearDown(c.close);
      final sending = c.send();
      await Future<void>.delayed(Duration.zero);
      expect(c.state.recipients.single.status, ShareRowStatus.sending);
      expect(c.state.sending, isTrue);
      hold.complete();
      await sending;
      expect(c.state.recipients.single.status, ShareRowStatus.sent);
    });

    test('notEncrypted falls back to sendMessage with the row key', () async {
      port.nextSendOutcome = const SendOutcome(SendOutcomeKind.notEncrypted);
      final c = withPort()..toggle(_peer(1));
      addTearDown(c.close);
      final key = c.state.recipients.single.key;
      await c.send();
      expect(c.state.recipients.single.status, ShareRowStatus.sent);
      expect(repo.sendKeys, [key]);
      expect(port.sent.single.localId, key);
    });

    test('refused marks the row failed with the outcome\'s error, or a text '
        'when there is none', () async {
      port.queueSendOutcomes([
        const SendOutcome(
          SendOutcomeKind.refused,
          problem: SendProblem.refused,
          error: CannotMessageException(),
        ),
        const SendOutcome(
          SendOutcomeKind.refused,
          problem: SendProblem.tryTomorrow,
        ),
      ]);
      final c = withPort()
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      await c.send();
      final rows = c.state.recipients;
      expect(rows[0].status, ShareRowStatus.failed);
      expect(rows[0].error, isA<CannotMessageException>());
      expect(rows[1].status, ShareRowStatus.failed);
      expect(rows[1].error!.message, kOutgoingTryTomorrowText);
      expect(repo.sendKeys, isEmpty);
    });

    test('the line drawn under the rows for a refusal with no error is the '
        'composer\'s text for it', () async {
      // The widget draws sharePostErrorMessage(lastError, problem: lastProblem).
      for (final (problem, text) in [
        (SendProblem.tryTomorrow, kOutgoingTryTomorrowText),
        (SendProblem.peerHasNoDevice, kStatePeerNoDeviceText),
      ]) {
        port.nextSendOutcome = SendOutcome(
          SendOutcomeKind.refused,
          problem: problem,
        );
        final c = withPort()..toggle(_peer(1));
        addTearDown(c.close);
        await c.send();
        expect(
          sharePostErrorMessage(
            c.state.lastError!,
            problem: c.state.lastProblem,
          ),
          text,
          reason: '$problem',
        );
      }
    });

    test('the share flag is checked before the port\'s send, so a disabled '
        'share sends nothing', () async {
      final c = withPort(isEnabled: () => false)..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expect(port.sent, isEmpty);
      expect(repo.sendKeys, isEmpty);
      expect(c.state.endedBy, isA<FeatureDisabledException>());
    });

    test(
      'a thrown error marks the row failed and reports a fixed error',
      () async {
        port.failNextOn('send', StateError('secret'));
        final reports = <Object>[];
        final c = SharePostCubit(
          repository: repo,
          postId: _postId,
          url: _url,
          encrypted: port,
          check: _passes,
          checkEnabled: () => true,
          onUnexpectedError: (e, _) => reports.add(e),
        )..toggle(_peer(1));
        addTearDown(c.close);
        await c.send();
        expect(c.state.recipients.single.status, ShareRowStatus.failed);
        expect(reports.single.toString(), isNot(contains('secret')));
      },
    );
  });

  group('the share check with an encrypted port', () {
    late FakeEncryptedMessaging port;
    late List<String> asked;

    /// What the check answers: a String is the id to share, anything else is
    /// thrown.
    late Object answer;
    Completer<void>? checkGate;
    var checkOn = true;

    Future<String> check(String id) async {
      asked.add(id);
      final gate = checkGate;
      if (gate != null) await gate.future;
      final a = answer;
      if (a is String) return a;
      throw a;
    }

    SharePostCubit make2({
      bool withCheck = true,
      void Function(Object, StackTrace)? onError,
      bool Function()? isEnabled,
    }) => SharePostCubit(
      repository: repo,
      postId: _postId,
      url: _url,
      ownUserId: 'u-me',
      isEnabled: isEnabled,
      encrypted: port,
      check: withCheck ? check : null,
      checkEnabled: () => checkOn,
      onUnexpectedError: onError ?? (_, _) => unexpected++,
    );

    setUp(() {
      port = FakeEncryptedMessaging();
      asked = [];
      answer = _postId;
      checkGate = null;
      checkOn = true;
    });
    tearDown(() => port.dispose());

    /// Zero sends, every row failed, and the text the bar draws.
    void expectRefused(SharePostCubit c, String text) {
      expect(port.sent, isEmpty);
      expect(repo.sendKeys, isEmpty);
      expect(
        c.state.recipients.map((r) => r.status),
        everyElement(ShareRowStatus.failed),
      );
      for (final r in c.state.recipients) {
        expect(sharePostErrorMessage(r.error!), text);
      }
      expect(
        sharePostErrorMessage(c.state.lastError!, problem: c.state.lastProblem),
        text,
      );
    }

    const notFoundText = "This post isn't available anymore.";
    const protectedText =
        "Only the author can send a protected account's post in a message.";
    const shareOffText =
        "Sending a post in a message isn't available right now.";

    // The plan's error table, as the repository delivers each answer.
    final refusals = <(String, AppException, String)>[
      ('NOT_FOUND', const NotFoundException('post not found'), notFoundText),
      ('PROTECTED_ACCOUNT', const ProtectedAccountException(), protectedText),
      (
        'UNAVAILABLE (protected set unreadable)',
        const NetworkException('temporarily busy'),
        sharePostErrorMessage(const NetworkException('x')),
      ),
      (
        'RATE_LIMITED',
        const RateLimitedException('slow'),
        sharePostErrorMessage(const RateLimitedException('x')),
      ),
      (
        'FEATURE_DISABLED (dm_post_share, also dm_share_check as re-thrown)',
        const FeatureDisabledException('off', feature: kFeatureDmPostShare),
        shareOffText,
      ),
      (
        'VALIDATION post_id',
        const ValidationException('bad', field: 'post_id'),
        "That post can't be sent. Check it and retry.",
      ),
    ];

    for (final (name, error, text) in refusals) {
      test('a $name answer refuses the share for every recipient before any '
          'send, with the existing copy', () async {
        answer = error;
        final c = make2()
          ..toggle(_peer(1))
          ..toggle(_peer(2));
        addTearDown(c.close);
        await c.send();
        expectRefused(c, text);
        expect(c.state.recipients.first.error, same(error));
        expect(asked, [_postId]);
        expect(unexpected, 0);
      });
    }

    test('the dm_share_check flag not in the enabled features: no call, no '
        'send, every row refused with the dm_post_share copy', () async {
      checkOn = false;
      final c = make2()
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      await c.send();
      expect(asked, isEmpty);
      expectRefused(c, shareOffText);
      expect(
        c.state.recipients.first.error,
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureDmPostShare,
        ),
      );
      expect(unexpected, 0);
    });

    test('a port with no check function refuses like the flag off', () async {
      final c = make2(withCheck: false)
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      await c.send();
      expect(asked, isEmpty);
      expectRefused(c, shareOffText);
    });

    test('a passing check shares the post: one call, one send per person with '
        'the id asked', () async {
      final c = make2()..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expect(asked, [_postId]);
      expect(c.state.allSent, isTrue);
      expect(port.sent.single.sharedPostId, _postId);
      expect(repo.sendKeys, isEmpty);
    });

    test('a repost shares the id the server returned, not the repost\'s '
        'own', () async {
      answer = '9999999999999999999';
      final c = make2()
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      await c.send();
      expect(asked, [_postId]);
      expect(c.state.allSent, isTrue);
      expect(port.sent.map((s) => s.sharedPostId), [
        '9999999999999999999',
        '9999999999999999999',
      ]);
    });

    test('one check for several recipients, before the first send', () async {
      final c = make2()
        ..toggle(_peer(1))
        ..toggle(_peer(2))
        ..toggle(_peer(3));
      addTearDown(c.close);
      await c.send();
      expect(asked, [_postId]);
      expect(port.sent, hasLength(3));
      expect(c.state.allSent, isTrue);
    });

    test('an unexpected error refuses the share, reports only a fixed error '
        'and carries no post detail', () async {
      answer = StateError('secret post text $_postId');
      final reports = <Object>[];
      final c = make2(onError: (e, _) => reports.add(e))
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      await c.send();
      expectRefused(c, protectedText);
      expect(reports, hasLength(1));
      expect(reports.single, isA<StateError>());
      expect(reports.single.toString(), 'Bad state: sharedPost');
      expect(c.state.toString(), isNot(contains('secret')));
      expect(c.state.toString(), isNot(contains(_postId)));
    });

    test('an answer with no id fails closed the same way', () async {
      answer = '';
      final reports = <Object>[];
      final c = make2(onError: (e, _) => reports.add(e))..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expectRefused(c, protectedText);
      expect(reports.single.toString(), 'Bad state: sharedPost');
    });

    test('a reporter that throws still leaves every row failed', () async {
      answer = StateError('boom');
      final c = make2(onError: (_, _) => throw StateError('reporter'))
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      await c.send();
      expectRefused(c, protectedText);
      expect(c.state.sending, isFalse);
    });

    test(
      'with no port the check is never asked and the share is today\'s',
      () async {
        final c = SharePostCubit(
          repository: repo,
          postId: _postId,
          url: _url,
          ownUserId: 'u-me',
          check: check,
          checkEnabled: () => true,
        )..toggle(_peer(1));
        addTearDown(c.close);
        await c.send();
        expect(asked, isEmpty);
        expect(repo.sendSharedPostIds, [_postId]);
        expect(c.state.allSent, isTrue);
      },
    );

    test('a second send while the check is pending does nothing', () async {
      checkGate = Completer<void>();
      final c = make2()..toggle(_peer(1));
      addTearDown(c.close);
      final first = c.send();
      await Future<void>.delayed(Duration.zero);
      expect(c.state.sending, isTrue);
      expect(c.state.canSend, isFalse);
      await c.send();
      expect(asked, [_postId]);
      checkGate!.complete();
      await first;
      expect(asked, [_postId]);
      expect(port.sent, hasLength(1));
    });

    test('rows after the first stay idle while the first send is pending '
        'after a passing check', () async {
      port.holdSend = Completer<void>();
      final c = make2()
        ..toggle(_peer(1))
        ..toggle(_peer(2));
      addTearDown(c.close);
      final sending = c.send();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.state.recipients[0].status, ShareRowStatus.sending);
      expect(c.state.recipients[1].status, ShareRowStatus.idle);
      port.holdSend!.complete();
      port.holdSend = null;
      await sending;
      expect(c.state.allSent, isTrue);
    });

    test('a retry after a refusal runs the check again', () async {
      answer = const ProtectedAccountException();
      final c = make2()..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expectRefused(c, protectedText);
      answer = _postId;
      await c.send();
      expect(asked, [_postId, _postId]);
      expect(c.state.allSent, isTrue);
      expect(c.state.lastError, isNull);
    });

    test('a retry that passes never re-emits the old failure', () async {
      answer = const NotFoundException('post not found');
      final c = make2()..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      answer = _postId;
      final errors = <Object?>[];
      final sub = c.stream.listen((s) {
        if (s.lastError != null) errors.add(s.lastError);
      });
      await c.send();
      await sub.cancel();
      expect(errors, isEmpty);
    });

    test('closing during a pending check sends nothing', () async {
      checkGate = Completer<void>();
      final c = make2()..toggle(_peer(1));
      final sending = c.send();
      await Future<void>.delayed(Duration.zero);
      await c.close();
      checkGate!.complete();
      await sending;
      expect(port.sent, isEmpty);
      expect(repo.sendKeys, isEmpty);
    });

    test('with a port and the share flag off, no check and no send '
        'happen', () async {
      final c = make2(isEnabled: () => false)..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expect(asked, isEmpty);
      expect(port.sent, isEmpty);
      expect(repo.sendKeys, isEmpty);
      expect(c.state.endedBy, isA<FeatureDisabledException>());
    });

    test('a share flag that turns on after the check was skipped sends '
        'nothing unchecked', () async {
      final flips = [false, true, true, true];
      final c = make2(isEnabled: () => flips.isEmpty ? true : flips.removeAt(0))
        ..toggle(_peer(1));
      addTearDown(c.close);
      await c.send();
      expect(asked, isEmpty);
      expect(port.sent, isEmpty);
      expect(repo.sendKeys, isEmpty);
      expect(c.state.endedBy, isA<FeatureDisabledException>());
    });
  });
}
