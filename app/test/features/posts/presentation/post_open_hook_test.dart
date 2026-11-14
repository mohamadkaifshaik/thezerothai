import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_detail_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockPostsRepository extends Mock implements PostsRepository {}

pb.PostView _view(String id) => pb.PostView(post: pb.Post(postId: id));

void main() {
  late _MockPostsRepository posts;

  setUp(() {
    posts = _MockPostsRepository();
    when(() => posts.removedPosts).thenAnswer((_) => const Stream.empty());
  });

  group('PostDetailCubit onOpened', () {
    test('fires once with the post id after a successful load', () async {
      when(() => posts.getPost('p1')).thenAnswer((_) async => _view('p1'));
      final opened = <String>[];
      final cubit = PostDetailCubit(
        postsRepository: posts,
        postId: 'p1',
        onOpened: opened.add,
      );
      await cubit.load();
      expect(opened, ['p1']);
      await cubit.close();
    });

    test('does not fire when the post is gone', () async {
      when(() => posts.getPost('p1'))
          .thenThrow(const NotFoundException('gone'));
      final opened = <String>[];
      final cubit = PostDetailCubit(
        postsRepository: posts,
        postId: 'p1',
        onOpened: opened.add,
      );
      await cubit.load();
      expect(opened, isEmpty);
      await cubit.close();
    });
  });

  group('ThreadCubit onOpened', () {
    test('fires on a first load, not on a pull-to-refresh', () async {
      when(() => posts.getThread('p1'))
          .thenAnswer((_) async => pb.GetThreadResponse(focal: _view('p1')));
      final opened = <String>[];
      final cubit = ThreadCubit(
        postsRepository: posts,
        postId: 'p1',
        onOpened: opened.add,
      );
      await cubit.load();
      expect(opened, ['p1']);
      await cubit.refresh();
      expect(opened, ['p1']);
      await cubit.close();
    });
  });
}
