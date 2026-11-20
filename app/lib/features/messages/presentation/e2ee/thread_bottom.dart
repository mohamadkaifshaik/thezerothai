import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/encryption_access.dart';
import 'encryption_status.dart';
import 'widgets/conversation_state_notice.dart';

/// What the bottom of a ready, writable thread shows (Plan 5b, Task 5).
enum ThreadBottom {
  /// Today's area: the request banner or the composer (with the sender's
  /// note above it).
  ordinary,

  /// The ordinary composer, with a state notice above it.
  ordinaryWithNotice,

  /// A state notice in place of the composer.
  noticeInstead,

  /// The read-only line (the messaging read-only text): sending is refused and no
  /// state has words for it.
  readOnlyLine,

  /// R11: this device has no vault. The fixed notice line.
  notOnThisDevice,

  /// The connected status card replaces the composer.
  statusCard,

  /// Encrypted, but the port has not answered yet: nothing is drawn, so no
  /// composer flashes before `canSend` is known.
  waiting,
}

/// Pure. Order (first match): a received request keeps its banner (Accept,
/// Delete, Block stay reachable); a conversation not known to be encrypted is
/// today's; no usable vault (R11) or a status that says the vault is not open;
/// a status that blocks messaging with an open vault; the caller's messaging
/// being read-only (the composer draws its own line); then `security.canSend`
/// alone decides the composer, and the state only decides the notice.
ThreadBottom threadBottomOf({
  required bool receivedRequest,
  required bool messagingReadOnly,
  required bool mls,
  required bool vaultBlocked,
  required EncryptionStatus? status,
  required EncryptionAccess access,
  required ConversationSecurity? security,
}) {
  if (receivedRequest || !mls) return ThreadBottom.ordinary;
  if (vaultBlocked || (status?.vaultNotOpen ?? false)) {
    final drawsCard =
        status != null &&
        status.kind != EncryptionStatusKind.none &&
        access != EncryptionAccess.unsupported &&
        access != EncryptionAccess.hidden;
    return drawsCard ? ThreadBottom.statusCard : ThreadBottom.notOnThisDevice;
  }
  if (status?.blocksMessaging ?? false) return ThreadBottom.statusCard;
  if (security == null) return ThreadBottom.waiting;
  if (messagingReadOnly) return ThreadBottom.ordinary;
  final notice = conversationStateHasNotice(security);
  if (security.canSend) {
    return notice ? ThreadBottom.ordinaryWithNotice : ThreadBottom.ordinary;
  }
  return notice ? ThreadBottom.noticeInstead : ThreadBottom.readOnlyLine;
}
