import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'posts_fixtures.dart';
import 'scheduled_fixtures.dart';

/// What the fake server does with the answer of one call (the item is
/// committed first in every mode, like a server whose reply was lost).
enum ServerReply {
  /// Answer normally.
  ok,

  /// Commit, then fail the call with a [NetworkException]: the response was
  /// dropped on the way back.
  drop,

  /// Commit, then never answer: the process is killed while the request is
  /// in flight.
  hold,
}

/// One item the server accepted (a post, or a scheduled item).
class Accepted {
  Accepted(this.kind, this.key, this.text, this.mediaIds);

  /// `post` or `schedule`.
  final String kind;
  final String key;
  final String text;
  final List<String> mediaIds;
}

/// A [PostsRepository] that behaves like the backend for the rules the
/// drafts duplicate-publication matrix depends on (W6-38). Each rule names the
/// backend code it models:
///
/// - Replay first: `repo_create.go` `createAttempt` looks the key up BEFORE
///   it loads the media, so a retry with attached media replays (S2).
/// - The same key with another body: IDEMPOTENCY_KEY_REUSED
///   (`repo_create.go` `ErrIdempotencyKeyReused`; `service_scheduled.go`
///   `answerStored`). The body is text, media ids, alt texts and the reply
///   policy (plus the publish minute for a schedule).
/// - CreatePost claims media single use: `media/attach.go:87` refuses a doc
///   whose `PostID` is set, answered as MEDIA_NOT_READY (S4).
/// - SchedulePost only VALIDATES media (`repo_scheduled.go` `MediaIDs`
///   comment: "not attached or reserved"); the publish sweep attaches, so two
///   scheduled items may carry the same media until one publishes
///   ([publishDue]).
class FakePostsServer extends Fake implements PostsRepository {
  /// Scripted answers, consumed one per committed call; empty means [ServerReply.ok].
  final List<ServerReply> script = [];

  /// Errors thrown by the next calls BEFORE anything is committed (a refusal
  /// that creates nothing), one per call.
  final List<AppException> refusals = [];

  /// Every key that reached the server, in order (replays included).
  final List<String> receivedKeys = [];

  /// Distinct items accepted (a replay adds none).
  final List<Accepted> accepted = [];

  /// Items the publish sweep turned into posts.
  final List<Accepted> published = [];

  final Map<String, ({String body, Object result})> _byKey = {};
  final Set<String> _attachedMedia = {};
  int _next = 0;

  int get received => receivedKeys.length;

  @override
  bool subFeatureEnabled(String name) => true;

  @override
  Future<pb.PostView> createPost({
    required String idempotencyKey,
    required String text,
    String replyToPostId = '',
    String quoteOfPostId = '',
    List<String> mediaIds = const [],
    List<String> mediaAltTexts = const [],
    ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    DraftPoll? poll,
  }) async {
    receivedKeys.add(idempotencyKey);
    if (refusals.isNotEmpty) throw refusals.removeAt(0);
    final body =
        'post|$text|${mediaIds.join(',')}|${mediaAltTexts.join(',')}'
        '|${replyPolicy.value}|${poll?.choices.join(',')}';
    final seen = _byKey['post:$idempotencyKey'];
    if (seen != null) {
      if (seen.body != body) {
        throw const IdempotencyKeyReusedException('key reused');
      }
      return seen.result as pb.PostView;
    }
    if (mediaIds.any(_attachedMedia.contains)) {
      throw const MediaNotReadyException('one of the images is not ready');
    }
    _attachedMedia.addAll(mediaIds);
    final item = Accepted('post', idempotencyKey, text, mediaIds);
    accepted.add(item);
    final view = postView(++_next, text: text.isEmpty ? 'image' : text);
    _byKey['post:$idempotencyKey'] = (body: body, result: view);
    await _answer();
    return view;
  }

  @override
  Future<pb.ScheduledPost> schedulePost({
    required String idempotencyKey,
    required String text,
    required DateTime publishAt,
    List<String> mediaIds = const [],
    List<String> mediaAltTexts = const [],
    ReplyPolicy replyPolicy = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
  }) async {
    receivedKeys.add(idempotencyKey);
    if (refusals.isNotEmpty) throw refusals.removeAt(0);
    final minute = publishAt.toUtc().millisecondsSinceEpoch ~/ 60000;
    final body =
        'sched|$text|${mediaIds.join(',')}|${mediaAltTexts.join(',')}'
        '|${replyPolicy.value}|$minute';
    final seen = _byKey['sched:$idempotencyKey'];
    if (seen != null) {
      if (seen.body != body) {
        throw const IdempotencyKeyReusedException('key reused');
      }
      return seen.result as pb.ScheduledPost;
    }
    // Validated (unattached), not attached.
    if (mediaIds.any(_attachedMedia.contains)) {
      throw const MediaNotReadyException('one of the images is not ready');
    }
    accepted.add(Accepted('schedule', idempotencyKey, text, mediaIds));
    final item = scheduledPost(
      ++_next,
      text: text,
      publishAt: publishAt,
      media: mediaIds.length,
    );
    _byKey['sched:$idempotencyKey'] = (body: body, result: item);
    await _answer();
    return item;
  }

  /// Runs the publish sweep over every scheduled item in order: media is
  /// attached now, so an item whose media an earlier post already took fails
  /// (`INVALID_CONTENT` / MEDIA at publish) instead of publishing.
  void publishDue() {
    for (final item in accepted.where((a) => a.kind == 'schedule')) {
      if (published.contains(item)) continue;
      if (item.mediaIds.any(_attachedMedia.contains)) continue;
      _attachedMedia.addAll(item.mediaIds);
      published.add(item);
    }
  }

  Future<void> _answer() async {
    final reply = script.isEmpty ? ServerReply.ok : script.removeAt(0);
    switch (reply) {
      case ServerReply.ok:
        return;
      case ServerReply.drop:
        throw const NetworkException('connection lost');
      case ServerReply.hold:
        await Completer<void>().future;
    }
  }
}
