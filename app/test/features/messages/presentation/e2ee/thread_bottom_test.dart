import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_access.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/thread_bottom.dart';
import 'package:flutter_test/flutter_test.dart';

const _ready = ConversationSecurity(state: ConversationEncryptionState.ready);

EncryptionStatus _status(
  EncryptionStatusKind kind, {
  VaultStatus vault = VaultStatus.ready,
  EncryptionAccess access = EncryptionAccess.full,
}) => EncryptionStatus(kind: kind, vault: vault, access: access);

ThreadBottom _of({
  bool receivedRequest = false,
  bool messagingReadOnly = false,
  bool mls = true,
  bool vaultBlocked = false,
  EncryptionStatus? status,
  EncryptionAccess access = EncryptionAccess.full,
  ConversationSecurity? security = _ready,
}) => threadBottomOf(
  receivedRequest: receivedRequest,
  messagingReadOnly: messagingReadOnly,
  mls: mls,
  vaultBlocked: vaultBlocked,
  status: status,
  access: access,
  security: security,
);

void main() {
  test('a thread not known to be encrypted is today\'s', () {
    expect(_of(mls: false, security: null), ThreadBottom.ordinary);
    expect(
      _of(
        mls: false,
        status: _status(EncryptionStatusKind.unavailable),
        security: null,
      ),
      ThreadBottom.ordinary,
    );
  });

  test('a received request keeps the request area whatever else holds', () {
    expect(
      _of(receivedRequest: true, vaultBlocked: true),
      ThreadBottom.ordinary,
    );
  });

  test('no usable vault: the notice for unsupported and hidden, the card '
      'otherwise', () {
    expect(
      _of(vaultBlocked: true, access: EncryptionAccess.unsupported),
      ThreadBottom.notOnThisDevice,
    );
    expect(
      _of(vaultBlocked: true, access: EncryptionAccess.hidden),
      ThreadBottom.notOnThisDevice,
    );
    expect(
      _of(vaultBlocked: true),
      ThreadBottom.notOnThisDevice,
      reason: 'no status to draw',
    );
    expect(
      _of(
        vaultBlocked: true,
        status: _status(EncryptionStatusKind.keyLostPending),
      ),
      ThreadBottom.statusCard,
    );
  });

  test('a status that says the vault is not open counts even when the cubit '
      'still thinks it is usable', () {
    expect(
      _of(
        status: _status(
          EncryptionStatusKind.removedElsewhere,
          vault: VaultStatus.keyLost,
        ),
      ),
      ThreadBottom.statusCard,
    );
  });

  test('a blocking status with an open vault replaces the composer', () {
    expect(
      _of(status: _status(EncryptionStatusKind.engineUnavailable)),
      ThreadBottom.statusCard,
    );
    expect(
      _of(status: _status(EncryptionStatusKind.removedElsewhere)),
      ThreadBottom.statusCard,
    );
    expect(
      _of(status: _status(EncryptionStatusKind.offline)),
      ThreadBottom.ordinary,
    );
  });

  test('security not yet known draws nothing', () {
    expect(_of(security: null), ThreadBottom.waiting);
  });

  test('messaging read-only for the caller keeps priority over the table', () {
    expect(
      _of(
        messagingReadOnly: true,
        security: const ConversationSecurity(
          state: ConversationEncryptionState.stuck,
          canSend: false,
        ),
      ),
      ThreadBottom.ordinary,
    );
  });

  group('the composer follows canSend alone', () {
    for (final state in ConversationEncryptionState.values) {
      test('$state canSend=true', () {
        final r = _of(security: ConversationSecurity(state: state));
        expect(
          r == ThreadBottom.ordinary || r == ThreadBottom.ordinaryWithNotice,
          isTrue,
        );
      });
      test('$state canSend=false', () {
        final r = _of(
          security: ConversationSecurity(state: state, canSend: false),
        );
        expect(
          r == ThreadBottom.noticeInstead || r == ThreadBottom.readOnlyLine,
          isTrue,
        );
      });
    }

    test('which states carry a notice', () {
      ThreadBottom of(ConversationEncryptionState s, bool canSend) => _of(
        security: ConversationSecurity(state: s, canSend: canSend),
      );
      expect(
        of(ConversationEncryptionState.listUnverifiable, true),
        ThreadBottom.ordinaryWithNotice,
      );
      expect(
        of(ConversationEncryptionState.changesBlocked, true),
        ThreadBottom.ordinaryWithNotice,
      );
      expect(
        of(ConversationEncryptionState.changesBlocked, false),
        ThreadBottom.noticeInstead,
      );
      expect(
        of(ConversationEncryptionState.ready, false),
        ThreadBottom.readOnlyLine,
      );
      expect(
        of(ConversationEncryptionState.pendingRequest, false),
        ThreadBottom.readOnlyLine,
      );
    });
  });
}
