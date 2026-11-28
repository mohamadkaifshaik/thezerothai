import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

void main() {
  testWidgets('tapping a video poster opens its media route', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: PostMedia(
              postId: '123',
              media: [
                common.MediaRef(
                  contentType: 'video/mp4',
                  url: 'https://cdn.example/clip.mp4',
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/post/:id/photo/:index',
          builder: (_, state) => Text(
            '${state.pathParameters['id']} / ${state.pathParameters['index']}',
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.byTooltip('Play video'));
    await tester.pumpAndSettle();
    expect(find.text('123 / 1'), findsOneWidget);
  });

  testWidgets('sensitive clips hide their poster until revealed', (
    tester,
  ) async {
    final clip = common.MediaRef(
      url: 'https://cdn.example/clip.mp4',
      thumbUrl: 'https://cdn.example/poster.jpg',
      width: 640,
      height: 480,
      contentType: 'video/mp4',
      videoLabels: 2 | 8,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PostMedia(media: [clip])),
      ),
    );
    expect(find.text('Sensitive video'), findsOneWidget);
    expect(find.text('Violence'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsNothing);
    await tester.tap(find.text('Show video'));
    await tester.pump();
    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.text('Made with AI'), findsOneWidget);
    expect(find.byTooltip('Play video'), findsOneWidget);
  });

  for (final detail in [false, true]) {
    testWidgets('only the poster loads before play (detail $detail)', (
      tester,
    ) async {
      final clip = common.MediaRef(
        url: 'https://cdn.example/clip.mp4',
        thumbUrl: 'https://cdn.example/poster.jpg',
        width: 640,
        height: 480,
        contentType: 'video/mp4',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PostMedia(media: [clip], useFullImage: detail),
          ),
        ),
      );
      expect(find.byTooltip('Play video'), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        clip.thumbUrl,
      );
    });
  }
}
