import 'package:dzeroth/features/posts/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

pb.PostView _post(String id, String author, {String replyTo = ''}) =>
    pb.PostView(
      post: pb.Post(
        postId: id,
        replyToPostId: replyTo,
        author: common.AuthorSnapshot(userId: author, handle: author),
      ),
    );

/// `selfThreadLength` drives the "Thread · N posts" header line.
void main() {
  test('a lone post is not a thread', () {
    expect(ThreadState(focal: _post('a', 'u1')).selfThreadLength, 0);
  });

  test('no focal post: 0', () {
    expect(const ThreadState().selfThreadLength, 0);
  });

  test('root and focal by one author count 2', () {
    final root = _post('a', 'u1');
    final state = ThreadState(
      focal: _post('b', 'u1', replyTo: 'a'),
      parent: root,
      root: root,
    );
    expect(state.selfThreadLength, 2);
  });

  test('root, parent and focal count 3, no double count', () {
    final state = ThreadState(
      focal: _post('c', 'u1', replyTo: 'b'),
      parent: _post('b', 'u1', replyTo: 'a'),
      root: _post('a', 'u1'),
    );
    expect(state.selfThreadLength, 3);
  });

  test('a missing middle post: the length is unknown, no count', () {
    // a <- (b missing) <- c <- d: the parent answers something not loaded.
    final state = ThreadState(
      focal: _post('d', 'u1', replyTo: 'c'),
      parent: _post('c', 'u1', replyTo: 'b'),
      root: _post('a', 'u1'),
    );
    expect(state.selfThreadLength, 0);
  });

  test('a reply whose context is not loaded: no count', () {
    expect(
      ThreadState(focal: _post('b', 'u1', replyTo: 'a')).selfThreadLength,
      0,
    );
  });

  test('a context post by someone else: not a self-thread', () {
    final state = ThreadState(
      focal: _post('c', 'u1', replyTo: 'b'),
      parent: _post('b', 'u2', replyTo: 'a'),
      root: _post('a', 'u1'),
    );
    expect(state.selfThreadLength, 0);
  });

  test('an unavailable context: 0', () {
    expect(
      ThreadState(
        focal: _post('c', 'u1', replyTo: 'b'),
        parent: _post('b', 'u1', replyTo: 'a'),
        rootUnavailable: true,
      ).selfThreadLength,
      0,
    );
    expect(
      ThreadState(
        focal: _post('c', 'u1', replyTo: 'b'),
        parentUnavailable: true,
      ).selfThreadLength,
      0,
    );
  });

  test("the same author's replies that continue the chain count", () {
    final state = ThreadState(
      focal: _post('a', 'u1'),
      replies: [
        _post('b', 'u1', replyTo: 'a'),
        _post('x', 'u2', replyTo: 'a'),
        _post('c', 'u1', replyTo: 'b'),
      ],
    );
    expect(state.selfThreadLength, 3);
  });

  test("someone else's reply does not extend it", () {
    final state = ThreadState(
      focal: _post('a', 'u1'),
      replies: [
        _post('x', 'u2', replyTo: 'a'),
        _post('b', 'u1', replyTo: 'x'),
      ],
    );
    expect(state.selfThreadLength, 0);
  });

  group('selfThreadTail: the replies the chain continues with', () {
    String ids(ThreadState s) =>
        s.selfThreadTail.map((v) => v.post.postId).join(',');

    test("the author's chain in order; others and side replies left out", () {
      final state = ThreadState(
        focal: _post('a', 'u1'),
        replies: [
          _post('b', 'u1', replyTo: 'a'),
          _post('x', 'u2', replyTo: 'b'),
          _post('c', 'u1', replyTo: 'b'),
          _post('y', 'u1', replyTo: 'a'),
          _post('d', 'u1', replyTo: 'c'),
        ],
      );
      expect(state.selfThreadLength, 4);
      expect(ids(state), 'b,c,d');
    });

    test('not a self-thread: empty', () {
      final state = ThreadState(
        focal: _post('a', 'u1'),
        replies: [_post('b', 'u2', replyTo: 'a')],
      );
      expect(state.selfThreadTail, isEmpty);
    });

    test('a hidden reply ends the chain there', () {
      final state = ThreadState(
        focal: _post('a', 'u1'),
        replies: [
          _post('b', 'u1', replyTo: 'a'),
          _post('c', 'u1', replyTo: 'b'),
        ],
        hiddenReplies: const {'b'},
      );
      expect(state.selfThreadTail, isEmpty);
    });

    test('the last post of the chain open: no tail, still a thread', () {
      final state = ThreadState(
        focal: _post('c', 'u1', replyTo: 'b'),
        parent: _post('b', 'u1', replyTo: 'a'),
        root: _post('a', 'u1'),
      );
      expect(state.selfThreadLength, 3);
      expect(state.selfThreadTail, isEmpty);
    });
  });
}
