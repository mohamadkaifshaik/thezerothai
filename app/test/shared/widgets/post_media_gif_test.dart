import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/gif_badge.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

const _still = 'https://cdn.example/m/g1-abc_t.jpg';
const _full = 'https://cdn.example/m/g1-abc.gif';

common.MediaRef _gif({String alt = '', String url = _full}) => common.MediaRef(
  url: url,
  thumbUrl: _still,
  width: 320,
  height: 240,
  contentType: 'image/gif',
  altText: alt,
);

Widget _host(
  Widget child, {
  double width = 360,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  bool disableAnimations = false,
}) => MaterialApp(
  theme: buildAppTheme(brightness: brightness),
  builder: (context, app) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: disableAnimations,
    ),
    child: app!,
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

/// Every image URL a CachedNetworkImage on screen is asked to load.
Set<String> _urls(WidgetTester tester) => {
  for (final w in tester.widgetList<CachedNetworkImage>(
    find.byType(CachedNetworkImage),
  ))
    w.imageUrl,
};

void main() {
  void swallowImageErrors(WidgetTester tester) {
    // The test binding cannot download; the error widget shows instead.
    addTearDown(() => tester.takeException());
  }

  testWidgets('a list shows the still with a GIF badge and a play control', (
    tester,
  ) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(_host(PostMedia(media: [_gif()])));

    expect(find.byType(GifBadge), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(_urls(tester), {_still});
  });

  testWidgets('the full file is requested only after the tap', (tester) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(_host(PostMedia(media: [_gif()])));
    expect(_urls(tester), isNot(contains(_full)), reason: 'before the tap');

    await tester.tap(find.byType(PostMedia));
    await tester.pump();

    expect(_urls(tester), contains(_full), reason: 'after the tap');
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

    // A second tap is the user's pause: back to the still.
    await tester.tap(find.byType(PostMedia));
    await tester.pump();
    expect(_urls(tester), {_still});
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('the detail view starts paused too (F10)', (tester) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(
      _host(PostMedia(media: [_gif()], useFullImage: true)),
    );
    expect(_urls(tester), {_still});
  });

  testWidgets('reduced motion changes nothing: no autoplay, tap still plays', (
    tester,
  ) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(
      _host(PostMedia(media: [_gif()]), disableAnimations: true),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(_urls(tester), {_still});
    await tester.tap(find.byType(PostMedia));
    await tester.pump();
    expect(_urls(tester), contains(_full));
  });

  testWidgets('a GIF without a full URL shows the still and cannot play', (
    tester,
  ) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(_host(PostMedia(media: [_gif(url: '')])));
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    await tester.tap(find.byType(PostMedia));
    await tester.pump();
    expect(_urls(tester), {_still});
  });

  testWidgets('a photo is untouched: no badge, no play control', (
    tester,
  ) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(
      _host(
        PostMedia(
          media: [
            common.MediaRef(
              url: 'https://cdn.example/m/p.jpg',
              thumbUrl: 'https://cdn.example/m/p_t.jpg',
              contentType: 'image/jpeg',
              width: 4,
              height: 3,
            ),
          ],
        ),
      ),
    );
    expect(find.byType(GifBadge), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
  });

  testWidgets('semantics: a labelled button that says what a tap does', (
    tester,
  ) async {
    swallowImageErrors(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(PostMedia(media: [_gif(alt: 'a cat')])));

    expect(
      find.bySemanticsLabel('a cat, GIF, play'),
      findsOneWidget,
      reason: 'alt text first, then the kind and the action',
    );
    final node = tester.getSemantics(find.bySemanticsLabel('a cat, GIF, play'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(node.hint, 'Double tap to play');

    await tester.tap(find.byType(GifBadge));
    await tester.pump();
    expect(find.bySemanticsLabel('a cat, GIF, playing'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the ALT chip stays its own control next to the play tile', (
    tester,
  ) async {
    swallowImageErrors(tester);
    await tester.pumpWidget(_host(PostMedia(media: [_gif(alt: 'a cat')])));
    expect(find.byType(AltTextChip), findsOneWidget);
    // Tapping ALT opens the description, it does not start the GIF.
    await tester.tap(find.byType(AltTextChip));
    await tester.pumpAndSettle();
    expect(_urls(tester), isNot(contains(_full)));
  });

  for (final width in [360.0, 600.0, 1200.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '${width.toInt()} ${brightness.name} x$scale: no overflow, 48dp play',
          (tester) async {
            swallowImageErrors(tester);
            await tester.pumpWidget(
              _host(
                PostMedia(media: [_gif(alt: 'a cat')]),
                width: width,
                brightness: brightness,
                textScale: scale,
              ),
            );
            expect(tester.takeException(), isNull);
            final tile = tester.getSize(find.byType(AspectRatio));
            expect(tile.width, greaterThanOrEqualTo(48));
            expect(tile.height, greaterThanOrEqualTo(48));
            final play = tester.getSize(
              find
                  .ancestor(
                    of: find.byIcon(Icons.play_arrow_rounded),
                    matching: find.byType(SizedBox),
                  )
                  .first,
            );
            expect(play.shortestSide, greaterThanOrEqualTo(48));
          },
        );
      }
    }
  }
}
