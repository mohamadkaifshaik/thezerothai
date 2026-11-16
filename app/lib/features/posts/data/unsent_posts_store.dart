import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show immutable, kIsWeb;

import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import '../../media/domain/processed_image.dart';
import '../domain/composer_draft.dart';
import '../domain/reply_audience.dart';
import 'drafts_repository.dart' show kPostSendKeyWindow;

/// At most this many posts keep their photo bytes on the device (and, in the
/// sender, in memory): 4 posts of 4 photos. A further post keeps its text
/// only.
const kUnsentPostsWithPhotos = 4;

/// The most processed photo bytes (full + thumbnail) kept for one account.
/// A post that would pass it keeps its text only, and its row says so.
const kUnsentPhotoBytesCap = 24 * 1024 * 1024;

/// What the server refused, as stored (`clearFlags`): Edit takes it out.
const kClearCommunity = 1;
const kClearPlan = 2;
const kClearPoll = 4;
const kClearAudience = 8;
const kClearPhotos = 16;

/// One photo of an unsent post: the processed image, its alt text and the
/// media id of its finished upload ('' when it was not uploaded).
///
/// From [UnsentPostsStore.load] the image has its thumbnail and metadata but
/// EMPTY full bytes ([fullLoaded] false); [UnsentPostsStore.loadFull] brings
/// them when the post is retried or edited.
@immutable
class StoredPhoto {
  const StoredPhoto({
    required this.image,
    this.altText = '',
    this.mediaId = '',
  });
  final ProcessedImage image;
  final String altText;
  final String mediaId;

  bool get fullLoaded => image.fullBytes.isNotEmpty;

  int get byteCount => image.fullBytes.length + image.thumbBytes.length;
}

/// An unsent post as the device keeps it.
@immutable
class UnsentPostRecord {
  const UnsentPostRecord({
    required this.uid,
    required this.postId,
    required this.text,
    required this.author,
    required this.createdAt,
    this.poll,
    this.replyAudience = ReplyAudience.everyone,
    this.policy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    this.communityId = '',
    this.beaconId = '',
    this.gif = false,
    this.draftId,
    this.deleteDraftId,
    this.key,
    this.keyStartedAt,
    this.keyUsed = false,
    this.ambiguous = false,
    this.claimReused = false,
    this.photosKept = true,
    this.photoCount,
    this.photos = const [],
    this.errorText,
    this.canRetry = true,
    this.needsVerify = false,
    this.clearFlags = 0,
  });

  final String uid;
  final String postId;
  final String text;
  final common.AuthorSnapshot author;
  final DateTime createdAt;
  final DraftPoll? poll;
  final ReplyAudience replyAudience;
  final ReplyPolicy policy;
  final String communityId;
  final String beaconId;
  final bool gif;
  final String? draftId;
  final String? deleteDraftId;

  /// The idempotency key of this send and what is known about its use.
  final String? key;
  final DateTime? keyStartedAt;
  final bool keyUsed;
  final bool ambiguous;
  final bool claimReused;

  /// False when the photos were not kept (cap, web): text only on restore.
  final bool photosKept;

  /// How many photos the post has, also when they were not kept (null: the
  /// length of [photos]).
  final int? photoCount;
  final List<StoredPhoto> photos;

  /// How the send last ended (null: it was waiting).
  final String? errorText;
  final bool canRetry;
  final bool needsVerify;
  final int clearFlags;

  int get totalPhotos => photoCount ?? photos.length;
}

/// What [UnsentPostsStore.save] did with the photos.
enum UnsentSave {
  /// Text and photos are kept.
  full,

  /// The text is kept; the photos were not (the size cap, or the web).
  textOnly,
}

/// The device-only store of unsent posts that must survive a restart: posts
/// that waited for a connection or failed, with their processed photo bytes
/// (`UnsentPostEntries` / `UnsentPostPhotoEntries`, schema v15). 0 RPCs.
///
/// Privacy: every read and write is filtered by uid, a write under an ended
/// session is dropped (the epoch), and sign-out wipes both tables. Nothing
/// here logs: a post's text and bytes never reach a logger.
///
/// The web keeps no photo bytes (the browser's storage is the wrong place for
/// megabytes of a user's photos): there a restored post has its text only.
class UnsentPostsStore {
  UnsentPostsStore(
    this._db, {
    DateTime Function()? now,
    bool? keepsPhotoBytes,
    this.maxPostsWithPhotos = kUnsentPostsWithPhotos,
    this.maxBytes = kUnsentPhotoBytesCap,
  }) : _now = now ?? DateTime.now,
       keepsPhotoBytes = keepsPhotoBytes ?? !kIsWeb && !_db.keepsNothing;

  final AppDatabase _db;
  final DateTime Function() _now;

  /// False on the web (and with the keep-nothing database): photos are not
  /// stored.
  final bool keepsPhotoBytes;
  final int maxPostsWithPhotos;
  final int maxBytes;

  /// Writes (or rewrites) [record] and, when it has photos, their bytes, unless
  /// the cap or the platform forbids it. The epoch of the session that asked
  /// is checked inside the transaction.
  Future<UnsentSave> save(UnsentPostRecord record, {required int epoch}) {
    return _db.transaction(() async {
      if (!_db.sessionEpoch.allows(epoch)) return UnsentSave.textOnly;
      final photos = record.photos;
      var keep = photos.isNotEmpty && keepsPhotoBytes;
      if (keep) {
        final others = await _usage(record.uid, except: record.postId);
        final bytes = photos.fold<int>(0, (n, p) => n + p.byteCount);
        if (others.posts >= maxPostsWithPhotos ||
            others.bytes + bytes > maxBytes) {
          keep = false;
        }
      }
      final kept = record.photosKept && (photos.isEmpty || keep);
      await _photos(record.uid, record.postId).go();
      await _db
          .into(_db.unsentPostEntries)
          .insertOnConflictUpdate(
            UnsentPostEntriesCompanion.insert(
              uid: record.uid,
              postId: record.postId,
              postText: Value(record.text),
              pollJson: Value(
                record.poll == null ? '' : jsonEncode(record.poll!.toJson()),
              ),
              replyAudience: Value(record.replyAudience.name),
              policyValue: Value(record.policy.value),
              communityId: Value(record.communityId),
              beaconId: Value(record.beaconId),
              isGif: Value(record.gif),
              draftId: Value(record.draftId),
              deleteDraftId: Value(record.deleteDraftId),
              authorBytes: record.author.writeToBuffer(),
              sendKey: Value(record.key),
              keyStartedAt: Value(record.keyStartedAt),
              keyUsed: Value(record.keyUsed),
              keyAmbiguous: Value(record.ambiguous),
              claimReused: Value(record.claimReused),
              errorText: Value(record.errorText),
              canRetry: Value(record.canRetry),
              needsVerify: Value(record.needsVerify),
              clearFlags: Value(record.clearFlags),
              // Not kept: the cap or the platform refused them, or the caller
              // already lost them.
              photosKept: Value(kept),
              // The count stays when the photos were not kept: the restored
              // row still says it was a photo post.
              photoCount: Value(
                record.totalPhotos > photos.length
                    ? record.totalPhotos
                    : photos.length,
              ),
              createdAt: record.createdAt,
            ),
          );
      if (keep) {
        for (var i = 0; i < photos.length; i++) {
          final p = photos[i];
          final img = p.image;
          await _db
              .into(_db.unsentPostPhotoEntries)
              .insert(
                UnsentPostPhotoEntriesCompanion.insert(
                  uid: record.uid,
                  postId: record.postId,
                  position: i,
                  fullBytes: img.fullBytes,
                  thumbBytes: img.thumbBytes,
                  width: img.width,
                  height: img.height,
                  fullMd5: img.fullMd5,
                  thumbMd5: img.thumbMd5,
                  blurhash: img.blurhash,
                  contentType: img.contentType,
                  thumbContentType: Value(img.thumbContentType),
                  altText: Value(p.altText),
                  mediaId: Value(p.mediaId),
                ),
              );
        }
      }
      return kept ? UnsentSave.full : UnsentSave.textOnly;
    });
  }

  /// Updates what the send knows (its key, how it ended, the media ids of its
  /// finished uploads) and keeps everything else, the photo bytes included.
  /// No-op when the post is not stored. [mediaIds] is parallel to the stored
  /// photos; null leaves them as they are.
  Future<void> updateSend(
    String uid,
    String postId, {
    required int epoch,
    String? key,
    DateTime? keyStartedAt,
    required bool keyUsed,
    required bool ambiguous,
    String? errorText,
    bool canRetry = true,
    bool needsVerify = false,
    int clearFlags = 0,
    List<String>? mediaIds,
  }) {
    return _db.transaction(() async {
      if (!_db.sessionEpoch.allows(epoch)) return;
      await (_db.update(
        _db.unsentPostEntries,
      )..where((t) => t.uid.equals(uid) & t.postId.equals(postId))).write(
        UnsentPostEntriesCompanion(
          sendKey: Value(key),
          keyStartedAt: Value(keyStartedAt),
          keyUsed: Value(keyUsed),
          keyAmbiguous: Value(ambiguous),
          errorText: Value(errorText),
          canRetry: Value(canRetry),
          needsVerify: Value(needsVerify),
          clearFlags: Value(clearFlags),
        ),
      );
      if (mediaIds != null) {
        for (var i = 0; i < mediaIds.length; i++) {
          await (_db.update(_db.unsentPostPhotoEntries)..where(
                (t) =>
                    t.uid.equals(uid) &
                    t.postId.equals(postId) &
                    t.position.equals(i),
              ))
              .write(
                UnsentPostPhotoEntriesCompanion(mediaId: Value(mediaIds[i])),
              );
        }
      }
    });
  }

  /// [uid]'s stored posts, oldest first, with each photo's thumbnail and
  /// metadata but NOT its full bytes (see [loadFull]). Rows whose key or
  /// creation is older than the idempotency window are swept first.
  Future<List<UnsentPostRecord>> load(String uid) async {
    await sweepExpired();
    final rows =
        await (_db.select(_db.unsentPostEntries)
              ..where((t) => t.uid.equals(uid))
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(t.postId),
              ]))
            .get();
    final out = <UnsentPostRecord>[];
    for (final row in rows) {
      out.add(
        _fromRow(row, await _readPhotos(uid, row.postId, withFull: false)),
      );
    }
    return out;
  }

  /// The photos of one stored post with their full bytes (Retry, Edit).
  Future<List<StoredPhoto>> loadFull(String uid, String postId) =>
      _readPhotos(uid, postId, withFull: true);

  Future<List<StoredPhoto>> _readPhotos(
    String uid,
    String postId, {
    required bool withFull,
  }) async {
    final t = _db.unsentPostPhotoEntries;
    final query = _db.selectOnly(t)
      ..addColumns([
        t.position,
        t.thumbBytes,
        t.width,
        t.height,
        t.fullMd5,
        t.thumbMd5,
        t.blurhash,
        t.contentType,
        t.thumbContentType,
        t.altText,
        t.mediaId,
        if (withFull) t.fullBytes,
      ])
      ..where(t.uid.equals(uid) & t.postId.equals(postId))
      ..orderBy([OrderingTerm.asc(t.position)]);
    final rows = await query.get();
    return [
      for (final r in rows)
        StoredPhoto(
          image: ProcessedImage(
            fullBytes: withFull ? r.read(t.fullBytes)! : Uint8List(0),
            thumbBytes: r.read(t.thumbBytes)!,
            width: r.read(t.width)!,
            height: r.read(t.height)!,
            fullMd5: r.read(t.fullMd5)!,
            thumbMd5: r.read(t.thumbMd5)!,
            blurhash: r.read(t.blurhash)!,
            contentType: r.read(t.contentType)!,
            thumbContentType: r.read(t.thumbContentType)!,
          ),
          altText: r.read(t.altText)!,
          mediaId: r.read(t.mediaId)!,
        ),
    ];
  }

  /// Deletes every row whose key or creation is older than the idempotency
  /// window (the earlier of the two decides: a key can be older than the post
  /// that carries it), of any account.
  Future<int> sweepExpired() async {
    final cutoff = _now().subtract(kPostSendKeyWindow);
    final rows = await _db.select(_db.unsentPostEntries).get();
    var swept = 0;
    for (final row in rows) {
      final started = row.keyStartedAt;
      final earliest = started != null && started.isBefore(row.createdAt)
          ? started
          : row.createdAt;
      if (earliest.isAfter(cutoff)) continue;
      await delete(row.uid, row.postId);
      swept++;
    }
    return swept;
  }

  /// The launch purge: deletes every row whose uid is not [uid] (another
  /// account's bytes must never be readable by this one).
  Future<void> purgeOthers(String uid) async {
    await (_db.delete(
      _db.unsentPostPhotoEntries,
    )..where((t) => t.uid.equals(uid).not())).go();
    await (_db.delete(
      _db.unsentPostEntries,
    )..where((t) => t.uid.equals(uid).not())).go();
  }

  /// Removes one post (success, Dismiss, Edit). Unguarded: removing never
  /// leaks.
  Future<void> delete(String uid, String postId) async {
    await _photos(uid, postId).go();
    await (_db.delete(
      _db.unsentPostEntries,
    )..where((t) => t.uid.equals(uid) & t.postId.equals(postId))).go();
  }

  /// Removes every post of [uid] ("Delete unsent posts").
  Future<void> deleteAll(String uid) async {
    await (_db.delete(
      _db.unsentPostPhotoEntries,
    )..where((t) => t.uid.equals(uid))).go();
    await (_db.delete(
      _db.unsentPostEntries,
    )..where((t) => t.uid.equals(uid))).go();
  }

  /// Removes everything, of every account (sign-out).
  Future<void> deleteEverything() async {
    await _db.delete(_db.unsentPostPhotoEntries).go();
    await _db.delete(_db.unsentPostEntries).go();
  }

  /// How many of [uid]'s stored posts have no unsent-post (draft) row, again
  /// on every change: with the drafts' own count it is the real number of
  /// unsent posts on the device (a post whose draft row exists is counted
  /// there, an image-only post of a saved draft included).
  Stream<int> watchCountWithoutDraft(String uid) {
    return _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM unsent_post_entries u '
          'WHERE u.uid = ?1 AND NOT EXISTS ('
          'SELECT 1 FROM composer_draft_entries d '
          'WHERE d.uid = u.uid '
          'AND d.draft_id = COALESCE(u.draft_id, u.delete_draft_id))',
          variables: [Variable<String>(uid)],
          readsFrom: {_db.unsentPostEntries, _db.composerDraftEntries},
        )
        .watchSingle()
        .map((row) => row.read<int>('c'));
  }

  /// The stored photo bytes of [uid], all posts (tests and the cap).
  Future<int> storedBytes(String uid) async => (await _usage(uid)).bytes;

  DeleteStatement<$UnsentPostPhotoEntriesTable, UnsentPostPhotoRow> _photos(
    String uid,
    String postId,
  ) =>
      _db.delete(_db.unsentPostPhotoEntries)
        ..where((t) => t.uid.equals(uid) & t.postId.equals(postId));

  Future<({int posts, int bytes})> _usage(String uid, {String? except}) async {
    final rows = await _db
        .customSelect(
          'SELECT post_id AS post_id, '
          'SUM(LENGTH(full_bytes) + LENGTH(thumb_bytes)) AS bytes '
          'FROM unsent_post_photo_entries WHERE uid = ?1 GROUP BY post_id',
          variables: [Variable<String>(uid)],
          readsFrom: {_db.unsentPostPhotoEntries},
        )
        .get();
    var posts = 0;
    var bytes = 0;
    for (final r in rows) {
      if (r.read<String>('post_id') == except) continue;
      posts++;
      bytes += r.read<int>('bytes');
    }
    return (posts: posts, bytes: bytes);
  }

  static UnsentPostRecord _fromRow(
    UnsentPostRow row,
    List<StoredPhoto> photos,
  ) {
    Object? poll;
    if (row.pollJson.isNotEmpty) {
      try {
        poll = jsonDecode(row.pollJson);
      } on FormatException {
        poll = null;
      }
    }
    return UnsentPostRecord(
      uid: row.uid,
      postId: row.postId,
      text: row.postText,
      author: common.AuthorSnapshot.fromBuffer(row.authorBytes),
      createdAt: row.createdAt,
      poll: DraftPoll.fromJson(poll),
      replyAudience: ReplyAudience.values.firstWhere(
        (a) => a.name == row.replyAudience,
        orElse: () => ReplyAudience.everyone,
      ),
      policy:
          ReplyPolicy.valueOf(row.policyValue) ??
          ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
      communityId: row.communityId,
      beaconId: row.beaconId,
      gif: row.isGif,
      draftId: row.draftId,
      deleteDraftId: row.deleteDraftId,
      key: row.sendKey,
      keyStartedAt: row.keyStartedAt,
      keyUsed: row.keyUsed,
      ambiguous: row.keyAmbiguous,
      claimReused: row.claimReused,
      photosKept: row.photosKept,
      photoCount: row.photoCount,
      photos: photos,
      errorText: row.errorText,
      canRetry: row.canRetry,
      needsVerify: row.needsVerify,
      clearFlags: row.clearFlags,
    );
  }
}
