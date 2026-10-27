import 'dart:async';

import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';

import 'bookmarks_fixtures.dart';
import 'posts_fixtures.dart';

const likesService = '/dzeroth.engagement.v1.EngagementService/';
const likesListProcedure = '${likesService}ListLikedPosts';
const likesLikeProcedure = '${likesService}LikePost';
const likesUnlikeProcedure = '${likesService}UnlikePost';

/// A liked post as the list returns it: live counts, hydrated flag (only
/// meaningful while `engagement` is on for the caller).
pb.PostView likedView(
  int n, {
  String? text,
  bool liked = true,
  bool bookmarked = false,
}) => pb.PostView(
  post: pb.Post(
    postId: postId(n),
    text: text ?? 'Liked post number $n',
    author: common.AuthorSnapshot(
      userId: 'u$n',
      handle: 'user$n',
      displayName: 'User $n',
    ),
    likeCount: Int64(10 + n),
    repostCount: Int64(2),
    replyCount: Int64(3),
  ),
  likedByViewer: liked,
  bookmarkedByViewer: bookmarked,
);

/// A `ListLikedPosts` answer with explicit rows and the next-page token
/// [next] ("" ends the list).
eng.ListLikedPostsResponse likesPageOf(
  Iterable<pb.PostView> views, [
  String next = '',
]) => eng.ListLikedPostsResponse(posts: views, nextPageToken: next);

/// A `ListLikedPosts` answer with the liked posts [posts] (see [likedView]).
eng.ListLikedPostsResponse likesPage(List<int> posts, [String next = '']) =>
    likesPageOf([for (final n in posts) likedView(n)], next);

/// `ListLikedPosts`, `LikePost` and `UnlikePost` scripted by the test (plug
/// [handle] into a `FakeTransport`). Pass a [bookmarks] server to answer the
/// bookmark procedures through the same transport (the History screen uses
/// both).
class FakeLikesServer {
  FakeLikesServer({this.bookmarks});

  final FakeBookmarksServer? bookmarks;

  /// The page tokens of every list call, in order.
  final List<String> listTokens = [];

  /// The page sizes of every list call, in order.
  final List<int> listSizes = [];

  /// Every Like / Unlike request, in order.
  final List<Object> toggles = [];

  /// The answer to a list call by page token (a response, or a thrown error);
  /// a token without an entry answers an empty last page.
  final Map<String, FutureOr<Object> Function()> pages = {};

  /// Thrown by Like / Unlike when set.
  Object? toggleError;

  /// Like / Unlike wait for this before answering when set.
  Completer<void>? toggleGate;

  int get listCalls => listTokens.length;

  Future<Object> handle(String procedure, Object input) async {
    switch (procedure) {
      case likesListProcedure:
        final request = input as eng.ListLikedPostsRequest;
        listTokens.add(request.pageToken);
        listSizes.add(request.pageSize);
        final page = pages[request.pageToken];
        if (page == null) return likesPage(const []);
        return await page();
      case likesLikeProcedure:
      case likesUnlikeProcedure:
        toggles.add(input);
        await toggleGate?.future;
        final error = toggleError;
        if (error != null) throw error;
        final liking = procedure == likesLikeProcedure;
        final id = liking
            ? (input as eng.LikePostRequest).postId
            : (input as eng.UnlikePostRequest).postId;
        final engagement = eng.PostEngagement(
          postId: id,
          likedByViewer: liking,
          likeCount: Int64(liking ? 11 : 9),
        );
        return liking
            ? eng.LikePostResponse(engagement: engagement)
            : eng.UnlikePostResponse(engagement: engagement);
    }
    final other = bookmarks;
    if (other != null) return other.handle(procedure, input);
    throw StateError('unexpected $procedure');
  }
}
