import 'dart:typed_data';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/thread_view.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

// Plan 5a Task 13b, step 13b-i: the outgoing half of the pure thread mapping
// (`entryOfOutgoing`). The stored-row, line, preview and security mappings
// are step 13b-ii's.

// Any instant: the mapping copies it and compares it with nothing.
final _at = DateTime.now().toUtc();

Uint8List _content(String text, {String shared = ''}) => encodeMessageContent(
  text: text,
  sharedPostId: shared,
  reportKey: Uint8List(kReportKeyBytes),
);

OutgoingRow _row({
  OutgoingStatus5a status = OutgoingStatus5a.waiting,
  SendBlock waitingOn = SendBlock.none,
  AppException? error,
  String? errorName,
  bool retryable = false,
  bool tryTomorrow = false,
  Uint8List? content,
}) => OutgoingRow(
  localId: 'local-1',
  conversationId: '11111111111111111111111111111111',
  content: content ?? _content('hello'),
  createdAt: _at,
  status: status,
  waitingOn: waitingOn,
  error: error,
  errorName: errorName,
  retryable: retryable,
  tryTomorrow: tryTomorrow,
);

OutgoingRow _failed({
  AppException? error,
  String? errorName,
  bool retryable = true,
  bool tryTomorrow = false,
}) => _row(
  status: OutgoingStatus5a.failed,
  error: error,
  errorName: errorName,
  retryable: retryable,
  tryTomorrow: tryTomorrow,
);

const _ready = ConversationCryptoState(
  phase: ConversationPhase.ready,
  sendBlock: SendBlock.none,
  requestAccepted: true,
  incomingRequest: false,
  deviceListUnverifiable: false,
  unknownDevicePresent: false,
  committingPausedToday: false,
  unattributedPresent: false,
  myDeviceCount: 1,
  theirDeviceCount: 1,
  canReset: false,
);

ConversationCryptoState _blockedBy(SendBlock block) => ConversationCryptoState(
  phase: ConversationPhase.ready,
  sendBlock: block,
  requestAccepted: true,
  incomingRequest: false,
  deviceListUnverifiable: false,
  unknownDevicePresent: block == SendBlock.unknownDevice,
  committingPausedToday: false,
  unattributedPresent: block == SendBlock.unknownDevice,
  myDeviceCount: 1,
  theirDeviceCount: 1,
  canReset: false,
);

void main() {
  test('an outgoing entry is mine, carries its own text and shared post under '
      'the local id, and cannot be reported', () {
    final e = entryOfOutgoing(
      _row(content: _content('hi there', shared: 'post-9')),
      _ready,
    );
    expect(e.id, 'local-1');
    expect(e.at, _at);
    expect(e.mine, isTrue);
    expect(e.state, EncryptedMessageState.visible);
    expect(e.check, MessageCheck.ok);
    expect(e.text, 'hi there');
    expect(e.sharedPostId, 'post-9');
    expect(e.canReport, isFalse);
    expect(e.waitingToDecrypt, isFalse);
  });

  test('an own row whose bytes do not decode carries no text', () {
    final e = entryOfOutgoing(
      _row(content: Uint8List.fromList(const [0xff, 0xff, 0xff])),
      _ready,
    );
    expect(e.check, MessageCheck.undecodable);
    expect(e.text, '');
    expect(e.sharedPostId, '');
  });

  test(
    'outgoing rows map to waiting, sending and notSent with each problem',
    () {
      // Sending: stage encrypted, or the init of a provisional group.
      var e = entryOfOutgoing(_row(status: OutgoingStatus5a.sending), _ready);
      expect(
        (e.progress, e.problem, e.error),
        (SendProgress.sending, SendProblem.none, null),
      );

      // Waiting: held by syncing, an epoch to advance, a provisional group.
      for (final block in [
        SendBlock.none,
        SendBlock.notSynced,
        SendBlock.epochMustAdvance,
        SendBlock.provisional,
      ]) {
        e = entryOfOutgoing(_row(waitingOn: block), _ready);
        expect(
          (e.progress, e.problem),
          (SendProgress.waiting, SendProblem.none),
          reason: block.name,
        );
      }

      // Blocked: the row goes out by itself when the block clears.
      for (final block in [
        SendBlock.unknownDevice,
        SendBlock.stuck,
        SendBlock.waitingForWelcome,
        SendBlock.unavailable,
      ]) {
        e = entryOfOutgoing(_row(waitingOn: block), _ready);
        expect(
          (e.progress, e.problem, e.error),
          (SendProgress.notSent, SendProblem.blocked, null),
          reason: block.name,
        );
      }

      e = entryOfOutgoing(_row(waitingOn: SendBlock.peerHasNoDevice), _ready);
      expect(
        (e.progress, e.problem),
        (SendProgress.notSent, SendProblem.peerHasNoDevice),
      );

      e = entryOfOutgoing(_row(waitingOn: SendBlock.cannotMessage), _ready);
      expect(
        (e.progress, e.problem),
        (SendProgress.notSent, SendProblem.refused),
      );
      expect(e.error, isA<CannotMessageException>());
    },
  );

  test('a waiting row takes the conversation state\'s block when its own gate '
      'names none', () {
    final e = entryOfOutgoing(_row(), _blockedBy(SendBlock.unknownDevice));
    expect(
      (e.progress, e.problem),
      (SendProgress.notSent, SendProblem.blocked),
    );
    // A row that is already sending keeps sending.
    final s = entryOfOutgoing(
      _row(status: OutgoingStatus5a.sending),
      _blockedBy(SendBlock.unknownDevice),
    );
    expect(s.progress, SendProgress.sending);
  });

  test('a failed row with no typed error is retryable whatever its stored '
      'name, except a peer with no device', () {
    for (final name in [
      null,
      kStartErrorLookupFailed,
      kStartErrorUnavailable,
      kStartErrorInitDiscarded,
      'RateLimitedException',
      'FeatureDisabledException',
    ]) {
      final e = entryOfOutgoing(_failed(errorName: name), _ready);
      expect(
        (e.progress, e.problem, e.error),
        (SendProgress.notSent, SendProblem.retryable, null),
        reason: '$name',
      );
    }
    final e = entryOfOutgoing(
      _failed(errorName: kStartErrorPeerHasNoDevice),
      _ready,
    );
    expect(
      (e.progress, e.problem, e.error),
      (SendProgress.notSent, SendProblem.peerHasNoDevice, null),
    );
  });

  test('a row the peer cannot be messaged on is refused with that error, also '
      'after a restart forgot the typed error', () {
    for (final error in [const CannotMessageException(), null]) {
      final e = entryOfOutgoing(
        _failed(
          error: error,
          errorName: 'CannotMessageException',
          retryable: false,
        ),
        _ready,
      );
      expect(
        (e.progress, e.problem),
        (SendProgress.notSent, SendProblem.refused),
      );
      expect(e.error, isA<CannotMessageException>());
    }
  });

  test('a daily cap is tryTomorrow and carries no error', () {
    final e = entryOfOutgoing(
      _failed(
        error: const RateLimitedException('x', limitName: 'messages_daily'),
        errorName: 'RateLimitedException',
        tryTomorrow: true,
      ),
      _ready,
    );
    expect(
      (e.progress, e.problem, e.error),
      (SendProgress.notSent, SendProblem.tryTomorrow, null),
    );
  });

  test('a definitive typed refusal is refused with that error; a passing one '
      'is retryable', () {
    const definitive = <AppException>[
      FeatureDisabledException('x'),
      LimitReachedException('x'),
      NotFoundException('x'),
      ValidationException('x'),
      EncryptionRequiredException('x'),
    ];
    for (final error in definitive) {
      final e = entryOfOutgoing(_failed(error: error), _ready);
      expect(
        (e.problem, e.error),
        (SendProblem.refused, error),
        reason: '${error.runtimeType}',
      );
    }
    const passing = <AppException>[
      RateLimitedException('x', retryAfter: Duration(seconds: 5)),
      DegradedModeException('x'),
      NetworkException('x'),
      AccountRestrictedException('x'),
    ];
    for (final error in passing) {
      final e = entryOfOutgoing(_failed(error: error), _ready);
      expect(
        (e.problem, e.error),
        (SendProblem.retryable, null),
        reason: '${error.runtimeType}',
      );
    }
  });

  test('every error an outgoing entry carries has its own messaging line '
      '(gate item 25)', () {
    const generic = "Couldn't complete that. Please try again.";
    const errors = <AppException>[
      CannotMessageException(),
      FeatureDisabledException('x'),
      LimitReachedException('x'),
      NotFoundException('x'),
      ValidationException('x'),
      EncryptionRequiredException('x'),
      QuotaExceededException('x'),
      RateLimitedException('x', retryAfter: Duration(seconds: 5)),
      DegradedModeException('x'),
      NetworkException('x'),
      AccountRestrictedException('x'),
      EmailNotVerifiedException('x'),
      UnknownApiException('x'),
    ];
    for (final error in errors) {
      for (final row in [
        _failed(error: error),
        _failed(error: error, retryable: false),
      ]) {
        final carried = entryOfOutgoing(row, _ready).error;
        if (carried == null) continue;
        expect(
          messagingErrorMessage(carried),
          isNot(generic),
          reason: '${error.runtimeType}',
        );
      }
    }
  });
}
