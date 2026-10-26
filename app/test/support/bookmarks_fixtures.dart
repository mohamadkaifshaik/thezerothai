import 'dart:async';

import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;

import 'posts_fixtures.dart';

const bookmarksService = '/dzeroth.engagement.v1.EngagementService/';
const bookmarksListProcedure = '${bookmarksService}ListBookmarks';
const bookmarksAddProcedure = '${bookmarksService}AddBookmark';
const bookmarksRemoveProcedure = '${bookmarksService}RemoveBookmark';

/// A `ListBookmarks` answer with the posts [posts] (see [postView]) and the
/// next-page token [next].
eng.ListBookmarksResponse bookmarksPage(List<int> posts, [String next = '']) =>
    eng.ListBookmarksResponse(
      // Listed rows come hydrated: bookmarked_by_viewer is true (ADR-0023 D3).
      bookmarks: [
        for (final n in posts)
          eng.Bookmark(post: postView(n)..bookmarkedByViewer = true),
      ],
      nextPageToken: next,
    );

/// A `ListBookmarks` answer with explicit rows.
eng.ListBookmarksResponse bookmarksPageOf(
  Iterable<pb.PostView> views, [
  String next = '',
]) => eng.ListBookmarksResponse(
  bookmarks: [for (final v in views) eng.Bookmark(post: v)],
  nextPageToken: next,
);

/// `ListBookmarks`, `AddBookmark` and `RemoveBookmark` scripted by the test
/// (plug [handle] into a `FakeTransport`).
class FakeBookmarksServer {
  /// The page tokens of every list call, in order.
  final List<String> listTokens = [];

  /// Every Add / Remove request, in order.
  final List<Object> toggles = [];

  /// The answer to a list call by page token (a response, or a thrown error);
  /// a token without an entry answers an empty last page.
  final Map<String, FutureOr<Object> Function()> pages = {};

  /// Thrown by Add / Remove when set.
  Object? toggleError;

  /// Add / Remove wait for this before answering when set.
  Completer<void>? toggleGate;

  Future<Object> handle(String procedure, Object input) async {
    switch (procedure) {
      case bookmarksListProcedure:
        final request = input as eng.ListBookmarksRequest;
        listTokens.add(request.pageToken);
        final page = pages[request.pageToken];
        if (page == null) return bookmarksPage(const []);
        return await page();
      case bookmarksAddProcedure:
      case bookmarksRemoveProcedure:
        toggles.add(input);
        await toggleGate?.future;
        final error = toggleError;
        if (error != null) throw error;
        final id = input is eng.AddBookmarkRequest
            ? input.postId
            : (input as eng.RemoveBookmarkRequest).postId;
        return procedure == bookmarksAddProcedure
            ? eng.AddBookmarkResponse(
                state: eng.BookmarkState(postId: id, bookmarked: true),
              )
            : eng.RemoveBookmarkResponse(
                state: eng.BookmarkState(postId: id, bookmarked: false),
              );
    }
    throw StateError('unexpected $procedure');
  }
}
