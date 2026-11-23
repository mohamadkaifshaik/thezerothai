import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:video_player/video_player.dart';

void main() {
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
