import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show PageStorageBucket;

import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import '../../data/messaging_repository.dart';
import '../../domain/messaging_feature_gate.dart';
import 'conversations_cubit.dart';

/// The inbox and the Requests folder, hoisted above every placement of the
/// list (tablet plan section 5.2): the `/messages` route child, the band B
/// list pane built by `MainShell`, and the list pane of the Messages split
/// page (a root route, beside the `ShellRoute`). They are different widgets,
/// so without this crossing 840dp or switching conversations in the split
/// page would load the list again.
///
/// - **Lazy.** No cubit exists until a placement reads [cubitFor], and
///   reading sends nothing: the route's open loads (`open`), a list pane only
///   makes sure a load was started (`ensureLoaded`). The placements read it
///   only while `MessagingAccessBuilder` grants access, so nothing exists at
///   app start or for a caller without Messages.
/// - **Per account.** `AppWidget` registers [reset] with the account reset
///   (sign-out and a direct account switch) and calls [accessChanged] when
///   the flag set or the messaging gate changes: access `hidden` drops both
///   cubits. Read-only access keeps them (the list still works then).
/// - [bucketFor] holds one `PageStorageBucket` per folder for the split
///   page's list pane, which remounts on every conversation switch: its
///   scroll offset is restored from there. It is dropped with the cubits.
/// - Every drop ticks [changes], so a mounted placement rebinds.
///   Placements never close these cubits.
///
/// A plain object (not a `Listenable`) so it can be provided as a value.
class ConversationsSession {
  ConversationsSession({
    required MessagingRepository repository,
    this.onInboxSynced,
    this.onUnexpectedError,
    DateTime Function()? now,
  }) : _repository = repository,
       _now = now;

  final MessagingRepository _repository;
  final DateTime Function()? _now;

  /// The Messages badge re-syncs from a loaded Inbox first page.
  final void Function(List<pb.Conversation> rows, {required bool hasMore})?
  onInboxSynced;
  final void Function(Object error, StackTrace stack)? onUnexpectedError;

  final Map<Folder, ConversationsCubit> _cubits = {};
  final Map<Folder, PageStorageBucket> _buckets = {};
  bool _disposed = false;
  final ValueNotifier<int> _revision = ValueNotifier(0);

  /// Ticks when the cubits were dropped: a placement listening to it reads
  /// [cubitFor] again.
  Listenable get changes => _revision;

  /// The list of [folder] (created on first read; nothing is sent).
  ConversationsCubit cubitFor(Folder folder) {
    assert(!_disposed, 'ConversationsSession used after dispose');
    final key = _key(folder);
    return _cubits[key] ??= ConversationsCubit(
      repository: _repository,
      folder: key,
      now: _now,
      onUnexpectedError: onUnexpectedError,
      onInboxSynced: key == Folder.FOLDER_INBOX ? onInboxSynced : null,
    );
  }

  /// The scroll memory of the split page's list pane for [folder].
  PageStorageBucket bucketFor(Folder folder) =>
      _buckets[_key(folder)] ??= PageStorageBucket();

  @visibleForTesting
  ConversationsCubit? ifCreated(Folder folder) => _cubits[_key(folder)];

  static Folder _key(Folder folder) => folder == Folder.FOLDER_REQUESTS
      ? Folder.FOLDER_REQUESTS
      : Folder.FOLDER_INBOX;

  /// Sign-out or an account switch: forget both folders and their scroll
  /// memory (the next account reads fresh, empty cubits).
  void reset() {
    if (_disposed) return;
    if (_drop()) _notify();
  }

  /// What Messages offers the caller now: `hidden` drops both folders (the
  /// screens show nothing then and the router sends the caller Home);
  /// `full` and `readOnly` keep them.
  void accessChanged(MessagingAccess access) {
    if (_disposed || access != MessagingAccess.hidden) return;
    if (_drop()) _notify();
  }

  void _notify() => _revision.value++;

  bool _drop() {
    final had = _cubits.isNotEmpty || _buckets.isNotEmpty;
    for (final cubit in _cubits.values) {
      unawaited(cubit.close());
    }
    _cubits.clear();
    _buckets.clear();
    return had;
  }

  void dispose() {
    if (_disposed) return;
    _drop();
    _disposed = true;
    _revision.dispose();
  }
}
