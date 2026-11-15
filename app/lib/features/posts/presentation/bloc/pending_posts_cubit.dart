import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;

/// Where a [PendingPost] is in its life.
enum PendingPostStatus {
  /// The undo window after Post: nothing is uploaded or sent yet.
  holding,

  /// Uploading photos or waiting for CreatePost.
  sending,

  /// Queued: waiting for a connection, or for the next retry after a network
  /// error. It sends by itself, in order, and can still be edited or dismissed.
  waiting,

  /// Stopped with [PendingPost.error]; the user may retry or edit.
  failed,

  /// The server accepted it; the row shows "Posted" for a moment.
  posted,
}

/// A post the user just sent that the server has not confirmed yet. Lives in
/// memory only: the status row on Home shows it while it sends, says
/// "Posted" briefly once `CreatePost` succeeds (the repository has already
/// put the real post into the cached feeds) and then drops it. A failed one
/// stays until the user retries, edits or dismisses it.
@immutable
class PendingPost {
  const PendingPost({
    required this.localId,
    required this.text,
    required this.author,
    required this.createdAt,
    this.thumbnails = const [],
    this.status = PendingPostStatus.sending,
    this.photosDone = 0,
    this.photosTotal = 0,
    this.uploading = false,
    this.error,
    this.canRetry = true,
    this.draftId,
    this.notice,
    this.keepsPhotos = true,
    this.needsVerify = false,
    this.holdSeconds = 0,
    this.waitingForConnection = true,
    this.photosNotSaved = false,
  });

  /// Unique per pending post (the optimistic row's id).
  final String localId;

  /// The normalised text the server will store.
  final String text;

  /// The viewer's own snapshot, so the row can show the avatar.
  final common.AuthorSnapshot author;
  final DateTime createdAt;

  /// On-device previews of the attached photos (already in memory, so the
  /// row shows them with no download).
  final List<Uint8List> thumbnails;

  final PendingPostStatus status;

  /// Photos finished / attached while [uploading].
  final int photosDone;
  final int photosTotal;

  /// Photos are being uploaded (as opposed to the CreatePost call).
  final bool uploading;

  /// Why it failed (user-facing copy), when [status] is failed.
  final String? error;

  /// Retrying is safe and useful; false when only Edit makes sense.
  final bool canRetry;

  /// The unsent-post row that keeps the text on this device; Edit reopens
  /// the composer on it. Null when unsent posts are off.
  final String? draftId;

  /// A warning on the "Posted" row (the server dropped a field).
  final String? notice;

  /// Edit brings the photos back into the composer (false: only the text).
  final bool keepsPhotos;

  /// The server wants a verified email: the row offers "Verify email".
  final bool needsVerify;

  /// The length of the undo window, in whole seconds, while [status] is
  /// holding (the row counts it down).
  final int holdSeconds;

  /// While [status] is waiting: true when the device is offline, false when
  /// the server could not be reached and a retry is coming.
  final bool waitingForConnection;

  /// The photos could not be kept on the device (too many unsent photos, or
  /// the web): closing the app loses them, the text is kept.
  final bool photosNotSaved;

  /// 0..1 upload progress, or null when it is not a photo upload.
  double? get progress =>
      uploading && photosTotal > 0 ? photosDone / photosTotal : null;

  PendingPost copyWith({
    PendingPostStatus? status,
    int? photosDone,
    int? photosTotal,
    bool? uploading,
    String? error,
    bool clearError = false,
    bool? canRetry,
    String? notice,
    List<Uint8List>? thumbnails,
    bool? keepsPhotos,
    bool? needsVerify,
    int? holdSeconds,
    bool? waitingForConnection,
    bool? photosNotSaved,
  }) => PendingPost(
    localId: localId,
    text: text,
    author: author,
    createdAt: createdAt,
    thumbnails: thumbnails ?? this.thumbnails,
    status: status ?? this.status,
    photosDone: photosDone ?? this.photosDone,
    photosTotal: photosTotal ?? this.photosTotal,
    uploading: uploading ?? this.uploading,
    error: clearError ? null : (error ?? this.error),
    canRetry: canRetry ?? this.canRetry,
    draftId: draftId,
    notice: notice ?? this.notice,
    keepsPhotos: keepsPhotos ?? this.keepsPhotos,
    needsVerify: needsVerify ?? this.needsVerify,
    holdSeconds: holdSeconds ?? this.holdSeconds,
    waitingForConnection: waitingForConnection ?? this.waitingForConnection,
    photosNotSaved: photosNotSaved ?? this.photosNotSaved,
  );
}

/// Session-wide list of [PendingPost]s, newest first. Home and the own
/// profile's Posts tab render `PendingPostsSection` above their feed,
/// so an optimistic post shows at the top without touching drift.
class PendingPostsCubit extends Cubit<List<PendingPost>> {
  PendingPostsCubit() : super(const []);

  void add(PendingPost post) {
    emit([post, ...state.where((p) => p.localId != post.localId)]);
  }

  /// Replaces the entry [localId] with [change] of it (no-op when gone).
  void update(String localId, PendingPost Function(PendingPost) change) {
    if (isClosed || state.every((p) => p.localId != localId)) return;
    emit([for (final p in state) p.localId == localId ? change(p) : p]);
  }

  void remove(String localId) {
    if (state.every((p) => p.localId != localId)) return;
    emit([
      for (final p in state)
        if (p.localId != localId) p,
    ]);
  }

  /// Sign-out: nothing of the previous session may linger (the privacy rule).
  void clear() {
    if (state.isNotEmpty) emit(const []);
  }
}
