import 'dart:typed_data';

import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationCryptoState _ready({
  ConversationPhase phase = ConversationPhase.ready,
  bool requestAccepted = true,
  bool deviceListUnverifiable = false,
  bool unknownDevicePresent = false,
  bool unattributedPresent = false,
}) => ConversationCryptoState(
  phase: phase,
  sendBlock: SendBlock.none,
  requestAccepted: requestAccepted,
  incomingRequest: false,
  deviceListUnverifiable: deviceListUnverifiable,
  unknownDevicePresent: unknownDevicePresent,
  committingPausedToday: false,
  unattributedPresent: unattributedPresent,
  myDeviceCount: 1,
  theirDeviceCount: 2,
  canReset: false,
);

void main() {
  test('equal states are equal and hash alike', () {
    final at = DateTime.now().toUtc();
    ConversationCryptoState make() => ConversationCryptoState(
      phase: ConversationPhase.ready,
      sendBlock: SendBlock.notSynced,
      requestAccepted: true,
      incomingRequest: true,
      deviceListUnverifiable: false,
      unknownDevicePresent: true,
      committingPausedToday: false,
      unattributedPresent: true,
      myDeviceCount: 2,
      theirDeviceCount: 3,
      canReset: true,
      resetAllowedAt: at,
    );
    expect(make(), make());
    expect(make().hashCode, make().hashCode);
    expect(make() == _ready(), isFalse);
    expect(ConversationCryptoState.initial, ConversationCryptoState.initial);
    expect(
      ConversationCryptoState.initial.phase,
      ConversationPhase.notEncrypted,
    );
    expect(ConversationCryptoState.initial.sendBlock, SendBlock.none);
  });

  test('codeAvailable is false with an unknown device, with an unverifiable '
      'list, in an unaccepted conversation and outside ready', () {
    expect(_ready().codeAvailable, isTrue);
    expect(_ready(unknownDevicePresent: true).codeAvailable, isFalse);
    expect(_ready(deviceListUnverifiable: true).codeAvailable, isFalse);
    expect(_ready(requestAccepted: false).codeAvailable, isFalse);
    for (final p in ConversationPhase.values) {
      if (p == ConversationPhase.ready) continue;
      expect(_ready(phase: p).codeAvailable, isFalse, reason: p.name);
    }
  });

  test('codeAvailable is false while any member is unattributed and on a '
      'provisional group', () {
    expect(_ready(unattributedPresent: true).codeAvailable, isFalse);
    expect(_ready(phase: ConversationPhase.provisional).codeAvailable, isFalse);
  });

  test('OutgoingRow keeps Object.toString', () {
    final row = OutgoingRow(
      localId: 'local-secret',
      conversationId: 'conv-secret',
      content: Uint8List.fromList([1, 2, 3]),
      createdAt: DateTime.now(),
      status: OutgoingStatus5a.waiting,
      waitingOn: SendBlock.notSynced,
      error: null,
      retryable: true,
      tryTomorrow: false,
    );
    expect(row.toString(), "Instance of 'OutgoingRow'");
  });

  test('ConversationCryptoState.toString holds no id', () {
    final text = _ready().toString();
    expect(text, contains('ready'));
    expect(text, contains('none'));
    expect(text, contains('true'));
    expect(text, contains('myDeviceCount: 1'));
    expect(text, isNot(contains('conv')));
  });

  test('the key history flags default to false and take part in equality '
      'and toString', () {
    ConversationCryptoState make({
      bool closed = false,
      bool mayAllow = false,
    }) => ConversationCryptoState(
      phase: ConversationPhase.ready,
      sendBlock: SendBlock.none,
      requestAccepted: true,
      incomingRequest: false,
      deviceListUnverifiable: false,
      unknownDevicePresent: false,
      committingPausedToday: false,
      unattributedPresent: false,
      myDeviceCount: 1,
      theirDeviceCount: 2,
      canReset: false,
      keyHistoryClosed: closed,
      mayAllowMoreDevices: mayAllow,
    );
    expect(_ready().keyHistoryClosed, isFalse);
    expect(_ready().mayAllowMoreDevices, isFalse);
    expect(ConversationCryptoState.initial.keyHistoryClosed, isFalse);
    expect(ConversationCryptoState.initial.mayAllowMoreDevices, isFalse);
    expect(make(), _ready());
    expect(make(closed: true) == make(), isFalse);
    expect(make(closed: true, mayAllow: true) == make(closed: true), isFalse);
    expect(
      make(closed: true, mayAllow: true).hashCode,
      make(closed: true, mayAllow: true).hashCode,
    );
    final text = make(closed: true).toString();
    expect(text, contains('keyHistoryClosed: true'));
    expect(text, contains('mayAllowMoreDevices: false'));
  });

  test('E2eePipelineError names the step only', () {
    expect(
      const E2eePipelineError('join').toString(),
      'E2eePipelineError(join)',
    );
  });
}
