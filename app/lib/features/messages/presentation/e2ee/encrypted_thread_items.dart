import '../../domain/e2ee/encrypted_messaging.dart';
import '../../domain/e2ee/message_content_codec.dart';
import '../thread_items.dart';
import '../widgets/message_bubble.dart'
    show kMessageDeletedText, kMessageRemovedText;
import 'encryption_copy.dart';

/// What a bubble shows for [m]: the text of a visible, verified message, or the
/// fixed placeholder of its state or check. The `text` of any other row is never
/// read.
String encryptedDisplayText(DecryptedMessage m) {
  return switch (m.state) {
    EncryptedMessageState.visible => switch (m.check) {
      MessageCheck.ok => m.text,
      MessageCheck.unverified => kCouldNotVerifyText,
      MessageCheck.undecodable => kCannotDisplayText,
    },
    EncryptedMessageState.undecryptable => kCouldNotDecryptText,
    EncryptedMessageState.removed => kMessageRemovedText,
    EncryptedMessageState.deletedAccount => kMessageDeletedText,
  };
}

/// Anything but a visible, verified message.
bool encryptedIsPlaceholder(DecryptedMessage m) =>
    m.state != EncryptedMessageState.visible || m.check != MessageCheck.ok;

DateTime _dayOf(DateTime utc) {
  final local = utc.toLocal();
  return DateTime(local.year, local.month, local.day);
}

bool _isUndecryptable(ThreadEntry e) =>
    e is DecryptedMessage && e.state == EncryptedMessageState.undecryptable;

/// Whether [a] and [b] (adjacent, same day) belong to one group: two messages
/// from the same side, neither undecryptable (its side is not reliable).
bool _sameGroup(ThreadEntry a, ThreadEntry b) =>
    a is DecryptedMessage &&
    b is DecryptedMessage &&
    !_isUndecryptable(a) &&
    !_isUndecryptable(b) &&
    a.mine == b.mine;

/// Newest-first [newestFirst] entries into newest-first rows, grouped by `mine`
/// within one local day with a day separator above the first row of each day,
/// as `buildThreadItems` does.
///
/// - A system line breaks a group. An `undecryptable` row never joins a group
///   and never starts one by `mine`: it is its own item and breaks the group
///   before and after it.
/// - `deviceAdded` on the caller's own side is an [OwnDeviceAlertItem].
/// - Of the `encryptionReset` lines on one local calendar day only the newest
///   is kept.
/// - [showLines] false (an unaccepted incoming request) drops every system line
///   and alert. Lines are dropped before grouping, so they leave no group break.
/// - The order of [newestFirst] is never changed.
List<ThreadItem> buildEncryptedThreadItems(
  List<ThreadEntry> newestFirst, {
  bool showLines = true,
}) {
  final keptNewestFirst = <ThreadEntry>[];
  final resetDays = <DateTime>{};
  for (final entry in newestFirst) {
    if (entry is SystemLineEntry) {
      if (!showLines) continue;
      if (entry.kind == SystemLineKind.encryptionReset &&
          !resetDays.add(_dayOf(entry.at))) {
        continue;
      }
    }
    keptNewestFirst.add(entry);
  }

  final chronological = keptNewestFirst.reversed.toList(growable: false);
  final rows = <ThreadItem>[];
  DateTime? lastDay;
  for (var i = 0; i < chronological.length; i++) {
    final entry = chronological[i];
    final day = _dayOf(entry.at);
    final newDay = day != lastDay;
    if (newDay) rows.add(DaySeparatorItem(day));
    lastDay = day;

    switch (entry) {
      case final SystemLineEntry line:
        rows.add(
          line.kind == SystemLineKind.deviceAdded && line.side == LineSide.mine
              ? OwnDeviceAlertItem(line)
              : SystemLineItem(line),
        );
      case final DecryptedMessage message:
        final previous = i == 0 ? null : chronological[i - 1];
        final next = i == chronological.length - 1
            ? null
            : chronological[i + 1];
        final firstOfGroup =
            previous == null || newDay || !_sameGroup(previous, entry);
        final nextStartsDay = next != null && _dayOf(next.at) != day;
        final lastOfGroup =
            next == null || nextStartsDay || !_sameGroup(entry, next);
        rows.add(
          EncryptedMessageItem(
            message,
            firstOfGroup: firstOfGroup,
            lastOfGroup: lastOfGroup,
          ),
        );
    }
  }
  return rows.reversed.toList(growable: false);
}
