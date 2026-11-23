import 'dart:typed_data';

import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/deferred_record.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/thread_view.dart';
import 'package:flutter_test/flutter_test.dart';

// Plan 5a Task 13b, step 13b-ii: the stored-row, system-line, deferred,
// preview and security halves of the pure thread mapping (gate items 26-28,
// 38). The outgoing half is in thread_view_test.dart (step 13b-i).

const _c1 = '11111111111111111111111111111111';

Uint8List _content(String text, {String shared = ''}) => encodeMessageContent(
  text: text,
  sharedPostId: shared,
  reportKey: Uint8List(kReportKeyBytes),
);

StoredMessage _row({
  String id = 'm1',
  int at = 5000000,
  bool mine = false,
  String state = StoredMessageState.visible,
  String check = StoredMessageCheck.ok,
  String kind = StoredMessageKind.message,
  Uint8List? content,
  bool noContent = false,
}) => StoredMessage(
  conversationId: _c1,
  messageId: id,
  createdAtMicros: at,
  mine: mine,
  state: state,
  generation: 1,
  epoch: 1,
  content: noContent ? null : (content ?? _content('hello')),
  check: check,
  kind: kind,
);

ConversationCryptoState _state({
  ConversationPhase phase = ConversationPhase.ready,
  SendBlock sendBlock = SendBlock.none,
  bool requestAccepted = true,
  bool incomingRequest = false,
  bool deviceListUnverifiable = false,
  bool unknownDevicePresent = false,
  bool committingPausedToday = false,
  bool unattributedPresent = false,
  int mine = 2,
  int theirs = 1,
  bool canReset = false,
}) => ConversationCryptoState(
  phase: phase,
  sendBlock: sendBlock,
  requestAccepted: requestAccepted,
  incomingRequest: incomingRequest,
  deviceListUnverifiable: deviceListUnverifiable,
  unknownDevicePresent: unknownDevicePresent,
  committingPausedToday: committingPausedToday,
  unattributedPresent: unattributedPresent,
  myDeviceCount: mine,
  theirDeviceCount: theirs,
  canReset: canReset,
);

ConversationEncryptionState _of(ConversationCryptoState s) =>
    securityOf(s, usable: true).state;

void main() {
  group('securityOf', () {
    test('states map in 5b\'s order, first that holds', () {
      final rows = <ConversationCryptoState, ConversationEncryptionState>{
        _state(requestAccepted: false, incomingRequest: true):
            ConversationEncryptionState.pendingRequest,
        _state(
          phase: ConversationPhase.waitingForWelcome,
          sendBlock: SendBlock.waitingForWelcome,
        ): ConversationEncryptionState.waitingForDevice,
        _state(phase: ConversationPhase.stuck, sendBlock: SendBlock.stuck):
            ConversationEncryptionState.stuck,
        _state(committingPausedToday: true):
            ConversationEncryptionState.changesBlocked,
        _state(
          unknownDevicePresent: true,
          unattributedPresent: true,
          sendBlock: SendBlock.unknownDevice,
        ): ConversationEncryptionState.unknownDevice,
        _state(deviceListUnverifiable: true):
            ConversationEncryptionState.listUnverifiable,
        _state(sendBlock: SendBlock.peerHasNoDevice):
            ConversationEncryptionState.peerHasNoDevice,
        _state(sendBlock: SendBlock.epochMustAdvance):
            ConversationEncryptionState.sendPaused,
        _state(sendBlock: SendBlock.notSynced):
            ConversationEncryptionState.syncing,
        _state(): ConversationEncryptionState.ready,
      };
      rows.forEach((s, expected) => expect(_of(s), expected, reason: '$s'));

      // Pairs: the earlier state wins.
      expect(
        _of(
          _state(
            committingPausedToday: true,
            unknownDevicePresent: true,
            unattributedPresent: true,
            sendBlock: SendBlock.unknownDevice,
          ),
        ),
        ConversationEncryptionState.changesBlocked,
      );
      expect(
        _of(
          _state(
            requestAccepted: false,
            incomingRequest: true,
            phase: ConversationPhase.stuck,
            committingPausedToday: true,
            deviceListUnverifiable: true,
          ),
        ),
        ConversationEncryptionState.pendingRequest,
      );
    });

    test('a provisional group is ready', () {
      expect(
        _of(
          _state(
            phase: ConversationPhase.provisional,
            sendBlock: SendBlock.provisional,
          ),
        ),
        ConversationEncryptionState.ready,
      );
    });

    test('a conversation the pipeline knows nothing about is ready and can '
        'send', () {
      final s = securityOf(ConversationCryptoState.initial, usable: true);
      expect(s.state, ConversationEncryptionState.ready);
      expect(s.canSend, isTrue);
      expect(s.sentRequest, isFalse);
    });

    test('canSend per state, and changesBlocked without an unknown device can '
        'send', () {
      bool canSend(ConversationCryptoState s) =>
          securityOf(s, usable: true).canSend;
      expect(
        canSend(_state(requestAccepted: false, incomingRequest: true)),
        isFalse,
      );
      expect(
        canSend(
          _state(
            phase: ConversationPhase.waitingForWelcome,
            sendBlock: SendBlock.waitingForWelcome,
          ),
        ),
        isFalse,
      );
      expect(
        canSend(
          _state(phase: ConversationPhase.stuck, sendBlock: SendBlock.stuck),
        ),
        isFalse,
      );
      expect(
        canSend(
          _state(
            unknownDevicePresent: true,
            unattributedPresent: true,
            sendBlock: SendBlock.unknownDevice,
          ),
        ),
        isFalse,
      );
      expect(canSend(_state(sendBlock: SendBlock.peerHasNoDevice)), isFalse);
      expect(canSend(_state(committingPausedToday: true)), isTrue);
      expect(
        canSend(
          _state(
            committingPausedToday: true,
            unknownDevicePresent: true,
            unattributedPresent: true,
            sendBlock: SendBlock.unknownDevice,
          ),
        ),
        isFalse,
      );
      for (final s in [
        _state(deviceListUnverifiable: true),
        _state(sendBlock: SendBlock.epochMustAdvance),
        _state(sendBlock: SendBlock.notSynced),
        _state(),
      ]) {
        expect(canSend(s), isTrue, reason: '$s');
        expect(securityOf(s, usable: false).canSend, isFalse, reason: '$s');
      }
    });

    test('counts are 0 in an unaccepted conversation and when not a member; a '
        'sent request has no reset', () {
      final sent = securityOf(
        _state(requestAccepted: false, canReset: true),
        usable: true,
      );
      expect(sent.sentRequest, isTrue);
      expect((sent.myDevices, sent.theirDevices), (0, 0));
      expect(sent.canReset, isFalse);
      final pending = securityOf(
        _state(requestAccepted: false, incomingRequest: true),
        usable: true,
      );
      expect(pending.sentRequest, isFalse);
      expect((pending.myDevices, pending.theirDevices), (0, 0));
      final waiting = securityOf(
        _state(
          phase: ConversationPhase.waitingForWelcome,
          sendBlock: SendBlock.waitingForWelcome,
        ),
        usable: true,
      );
      expect((waiting.myDevices, waiting.theirDevices), (0, 0));
      final ready = securityOf(_state(canReset: true), usable: true);
      expect((ready.myDevices, ready.theirDevices), (2, 1));
      expect(ready.canReset, isTrue);
      expect(
        securityOf(_state(canReset: true), usable: false).canReset,
        isFalse,
      );
    });
  });

  group('stored rows', () {
    test(
      'a visible ok row carries its text and the peer\'s can be reported',
      () {
        final e = entryOfStored(_row(content: _content('hi', shared: 'p-1')));
        expect((e.id, e.text, e.sharedPostId), ('m1', 'hi', 'p-1'));
        expect(e.at, DateTime.fromMicrosecondsSinceEpoch(5000000, isUtc: true));
        expect(e.progress, SendProgress.delivered);
        expect(e.canReport, isTrue);
        expect(e.waitingToDecrypt, isFalse);
      },
    );

    test('an unverified or undecodable row carries no text and can be '
        'reported; badReportKey is unverified (item 26)', () {
      final checks = {
        StoredMessageCheck.unverified: MessageCheck.unverified,
        StoredMessageCheck.badReportKey: MessageCheck.unverified,
        StoredMessageCheck.undecodable: MessageCheck.undecodable,
      };
      checks.forEach((stored, check) {
        final e = entryOfStored(_row(check: stored));
        expect(e.check, check, reason: stored);
        expect((e.text, e.sharedPostId), ('', ''), reason: stored);
        expect(e.canReport, isTrue, reason: stored);
      });
      // Bytes that do not decode under an ok check: undecodable.
      final bad = entryOfStored(
        _row(content: Uint8List.fromList(const [0xff, 0xff])),
      );
      expect((bad.check, bad.text), (MessageCheck.undecodable, ''));
    });

    test('my own rows cannot be reported', () {
      expect(entryOfStored(_row(mine: true)).canReport, isFalse);
    });

    test('tombstones and undecryptable rows carry no text and no report', () {
      final states = {
        StoredMessageState.removed: EncryptedMessageState.removed,
        StoredMessageState.deletedAccount: EncryptedMessageState.deletedAccount,
        StoredMessageState.undecryptable: EncryptedMessageState.undecryptable,
      };
      states.forEach((stored, state) {
        final e = entryOfStored(_row(state: stored, noContent: true));
        expect(e.state, state, reason: stored);
        expect(e.text, '', reason: stored);
        expect(e.canReport, isFalse, reason: stored);
      });
    });

    test('a system row maps to its kind and side and an undecodable one is '
        'dropped', () {
      SystemLineEntry? line(String l, {String? side}) => lineOfStored(
        _row(
          kind: StoredMessageKind.system,
          content: SystemLineContent(line: l, side: side).encode(),
        ),
      );
      expect(
        line(SystemLine.encryptionReset)!.kind,
        SystemLineKind.encryptionReset,
      );
      final added = line(SystemLine.deviceAdded, side: MemberSide.mine)!;
      expect(
        (added.kind, added.side),
        (SystemLineKind.deviceAdded, LineSide.mine),
      );
      final removed = line(SystemLine.deviceRemoved, side: MemberSide.theirs)!;
      expect(
        (removed.kind, removed.side),
        (SystemLineKind.deviceRemoved, LineSide.theirs),
      );
      expect(
        line(SystemLine.unknownDevice)!.kind,
        SystemLineKind.unknownDevice,
      );
      expect(line('somethingNew'), isNull);
      expect(
        lineOfStored(
          _row(
            kind: StoredMessageKind.system,
            content: Uint8List.fromList(const [1, 2, 3]),
          ),
        ),
        isNull,
      );
    });

    test('a deferred message is waiting to decrypt, with no side, text or '
        'report (item 27)', () {
      final e = entryOfDeferred(const DeferredView('d1', 7000000));
      expect(e.id, 'd1');
      expect(e.at, DateTime.fromMicrosecondsSinceEpoch(7000000, isUtc: true));
      expect(e.state, EncryptedMessageState.undecryptable);
      expect(e.waitingToDecrypt, isTrue);
      expect((e.mine, e.text, e.canReport), (false, '', false));
    });
  });

  group('previewOf', () {
    test('preview kinds for each row state, generic for an unaccepted incoming '
        'request and for no row', () {
      expect(previewOf(null, genericOnly: false).kind, PreviewKind.generic);
      expect(previewOf(_row(), genericOnly: true).kind, PreviewKind.generic);
      expect(previewOf(_row(), genericOnly: true).text, '');
      final kinds = {
        _row(state: StoredMessageState.removed, noContent: true):
            PreviewKind.removed,
        _row(state: StoredMessageState.deletedAccount, noContent: true):
            PreviewKind.deletedAccount,
        _row(state: StoredMessageState.undecryptable, noContent: true):
            PreviewKind.undecryptable,
        _row(check: StoredMessageCheck.unverified): PreviewKind.unverified,
        _row(check: StoredMessageCheck.badReportKey): PreviewKind.unverified,
        _row(check: StoredMessageCheck.undecodable): PreviewKind.undecodable,
        _row(content: _content('', shared: 'p-1')): PreviewKind.sharedPost,
        _row(): PreviewKind.text,
      };
      kinds.forEach((row, kind) {
        final p = previewOf(row, genericOnly: false);
        expect(p.kind, kind, reason: '${row.state} ${row.check}');
        if (kind != PreviewKind.text) expect(p.text, '');
      });
      expect(previewOf(_row(mine: true), genericOnly: false).mine, isTrue);
    });

    test('text is the first line, cut to 140 characters', () {
      final long = 'a' * 200;
      expect(
        previewOf(
          _row(content: _content('$long\nsecond')),
          genericOnly: false,
        ).text,
        'a' * 140,
      );
      expect(
        previewOf(_row(content: _content('one\ntwo')), genericOnly: false).text,
        'one',
      );
      // A character outside the BMP is never cut in half.
      final emoji = '\u{1F600}' * 150;
      final cut = previewOf(
        _row(content: _content(emoji)),
        genericOnly: false,
      ).text;
      expect(cut.runes.length, 140);
      expect(cut.runes.every((r) => r == 0x1F600), isTrue);
    });
  });
}
