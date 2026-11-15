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

/// At most this many posts keep their photo bytes on the device (4 posts of
/// 4 photos); a further post keeps its text only.
const kUnsentPostsWithPhotos = 4;

/// The most processed photo bytes (full + thumbnail) kept for one account.
/// A post that would pass it keeps its text only, and its row says so.
const kUnsentPhotoBytesCap = 24 * 1024 * 1024;

/// One photo of an unsent post: the processed image and its alt text.
@immutable
class StoredPhoto {
  const StoredPhoto({required this.image, this.altText = ''});
  final ProcessedImage image;
  final String altText;

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
    this.photos = const [],
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
  final List<StoredPhoto> photos;
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
              // Not kept: the cap or the platform refused them, or the caller
              // already lost them.
              photosKept: Value(kept),
              photoCount: Value(keep ? photos.length : 0),
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
                ),
              );
        }
      }
      return kept ? UnsentSave.full : UnsentSave.textOnly;
    });
  }

  /// Updates what the send knows about its key (and nothing else), keeping the
  /// stored photos. No-op when the post is not stored.
  Future<void> updateKey(
    String uid,
    String postId, {
    required int epoch,
    String? key,
    DateTime? keyStartedAt,
    required bool keyUsed,
    required bool ambiguous,
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
        ),
      );
    });
  }

  /// [uid]'s stored posts, oldest first. Rows older than the idempotency
  /// window are swept first, so a key past its window never comes back.
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
      final photos =
          await (_db.select(_db.unsentPostPhotoEntries)
                ..where((t) => t.uid.equals(uid) & t.postId.equals(row.postId))
                ..orderBy([(t) => OrderingTerm.asc(t.position)]))
              .get();
      out.add(_fromRow(row, photos));
    }
    return out;
  }

  /// Deletes every row older than the idempotency window, of any account.
  Future<int> sweepExpired() async {
    final cutoff = _now().subtract(kPostSendKeyWindow);
    final old = await (_db.select(
      _db.unsentPostEntries,
    )..where((t) => t.createdAt.isSmallerOrEqualValue(cutoff))).get();
    for (final row in old) {
      await delete(row.uid, row.postId);
    }
    return old.length;
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

  /// How many posts [uid] has stored, again on every change.
  Stream<int> watchCount(String uid) {
    final table = _db.unsentPostEntries;
    final total = table.postId.count();
    return (_db.selectOnly(table)
          ..addColumns([total])
          ..where(table.uid.equals(uid)))
        .map((row) => row.read(total) ?? 0)
        .watchSingle();
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
    List<UnsentPostPhotoRow> photos,
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
      photos: [
        for (final p in photos)
          StoredPhoto(
            image: ProcessedImage(
              fullBytes: p.fullBytes,
              thumbBytes: p.thumbBytes,
              width: p.width,
              height: p.height,
              fullMd5: p.fullMd5,
              thumbMd5: p.thumbMd5,
              blurhash: p.blurhash,
              contentType: p.contentType,
              thumbContentType: p.thumbContentType,
            ),
            altText: p.altText,
          ),
      ],
    );
  }
}
