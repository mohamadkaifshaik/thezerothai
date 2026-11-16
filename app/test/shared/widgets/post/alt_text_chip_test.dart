import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/post/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_pager.dart';

Widget _host(
  Widget child, {
  double width = 360,
  ThemeData? theme,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  theme: theme ?? appDarkTheme,
  builder: (context, app) => Directionality(
    textDirection: direction,
    child: MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: app!,
    ),
  ),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

common.MediaRef _ref({String alt = ''}) =>
    common.MediaRef(width: 4, height: 3, altText: alt);

/// The chip of the image whose description is [alt].
Finder _chipOf(String alt) =>
    find.byWidgetPredicate((w) => w is AltTextChip && w.text == alt);

/// The rounded frame (single image or tile) that holds [chip].
Finder _frameOf(Finder chip) =>
    find.ancestor(of: chip, matching: find.byType(ClipRRect)).first;

/// Scrolls the tile row so tile [index] starts at its left edge (or as near
/// as the row's end allows), building it. The row is lazy: tiles far off
/// screen do not exist.
Future<void> _reveal(WidgetTester tester, int index) async {
  final scrollable = find.descendant(
    of: find.byType(ListView),
    matching: find.byType(Scrollable),
  );
  final position = tester.state<ScrollableState>(scrollable).position;
  final tile = tester.getSize(find.byType(ClipRRect).first);
  final step = tile.width + AppSize.postMediaRowGap;
  position.jumpTo((index * step).clamp(0.0, position.maxScrollExtent));
  await tester.pump();
}

void main() {
  final chip = find.byType(AltTextChip);

  testWidgets('no chip on an image without a description', (tester) async {
    await tester.pumpWidget(_host(PostMedia(media: [_ref(), _ref(), _ref()])));
    expect(chip, findsNothing);
    expect(find.text('ALT'), findsNothing);
    await swipeToNextMediaPage(tester);
    expect(currentMediaPage(tester), 1);
    expect(chip, findsNothing);
    expect(find.text('ALT'), findsNothing);
  });

  testWidgets('a chip only on the tiles that have a description', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PostMedia(
          media: [
            _ref(alt: 'a cat'),
            _ref(),
            _ref(alt: 'a dog'),
          ],
        ),
      ),
    );
    expect(_chipOf('a cat'), findsOneWidget);
    await _reveal(tester, 2);
    expect(_chipOf('a dog'), findsOneWidget);
    // The middle tile has none: a chip per described tile, never an empty one.
    expect(find.byWidgetPredicate((w) => w is AltTextChip && w.text.isEmpty),
        findsNothing);
    expect(find.text('ALT'), findsNWidgets(chip.evaluate().length));
  });

  testWidgets('each tile opens the sheet with its own description', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PostMedia(
          media: [
            _ref(alt: 'a cat'),
            _ref(alt: 'a dog'),
          ],
        ),
      ),
    );
    await tester.tap(_chipOf('a cat'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AltTextSheet),
        matching: find.text('a cat'),
      ),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(AltTextSheet), findsNothing);

    await _reveal(tester, 1);
    await tester.tap(_chipOf('a dog'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AltTextSheet),
        matching: find.text('a dog'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AltTextSheet),
        matching: find.text('a cat'),
      ),
      findsNothing,
    );
  });

  testWidgets('the chip is bottom-start of its tile with a 48dp target', (
    tester,
  ) async {
    await tester.pumpWidget(_host(PostMedia(media: [_ref(alt: 'a cat')])));
    final media = tester.getRect(_frameOf(chip));
    final target = tester.getRect(
      find.descendant(of: chip, matching: find.byType(ConstrainedBox)).first,
    );
    expect(target.left, closeTo(media.left, 1));
    expect(target.bottom, closeTo(media.bottom, 1));
    expect(target.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
    expect(target.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
  });

  testWidgets('in RTL the chip moves to the right edge', (tester) async {
    await tester.pumpWidget(
      _host(
        PostMedia(media: [_ref(alt: 'a cat')]),
        direction: TextDirection.rtl,
      ),
    );
    final media = tester.getRect(_frameOf(chip));
    final target = tester.getRect(
      find.descendant(of: chip, matching: find.byType(ConstrainedBox)).first,
    );
    expect(target.right, closeTo(media.right, 1));
  });

  testWidgets('tapping the chip opens a sheet with the description', (
    tester,
  ) async {
    await tester.pumpWidget(_host(PostMedia(media: [_ref(alt: 'a cat')])));
    expect(find.byType(AltTextSheet), findsNothing);

    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(find.byType(AltTextSheet), findsOneWidget);
    expect(find.text('Image description'), findsOneWidget);
    expect(find.text('a cat'), findsOneWidget);
  });

  testWidgets('semantics: the image label stays the description, the chip is '
      'its own button', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(PostMedia(media: [_ref(alt: 'a cat')])));

    expect(find.bySemanticsLabel('a cat'), findsOneWidget);
    expect(find.bySemanticsLabel('Image description'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Image description')),
      matchesSemantics(
        label: 'Image description',
        hint: 'Shows the description of the image',
        isButton: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        '4 images with descriptions, ${dark ? 'dark' : 'light'}, text scale '
        '$scale, 320 dp: no overflow',
        (tester) async {
          await tester.pumpWidget(
            _host(
              PostMedia(
                media: [for (var i = 0; i < 4; i++) _ref(alt: 'image $i')],
              ),
              width: 288,
              theme: dark ? appDarkTheme : appLightTheme,
              textScale: scale,
            ),
          );
          expect(mediaPageCount(tester), 4);
          expect(tester.takeException(), isNull);

          await tester.tap(_chipOf('image 0'));
          await tester.pumpAndSettle();
          expect(find.byType(AltTextSheet), findsOneWidget);
          expect(find.text('image 0'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();

          // Every tile has its own chip.
          for (var i = 0; i < 4; i++) {
            await _reveal(tester, i);
            expect(_chipOf('image $i'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          await tester.tap(_chipOf('image 3'));
          await tester.pumpAndSettle();
          expect(find.byType(AltTextSheet), findsOneWidget);
          expect(find.text('image 3'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a 1,000 character description scrolls in the sheet at 2.0', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        PostMedia(media: [_ref(alt: 'word ' * 200)]),
        width: 288,
        textScale: 2,
      ),
    );

    await tester.tap(chip);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(AltTextSheet),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
  });

  // ---------------------------------------------------------------------
  // (tester): the chip across the responsive matrix, and inside a
  // tappable card.
  // ---------------------------------------------------------------------

  group('W2-13 responsive matrix', () {
    for (final dark in [false, true]) {
      for (final width in const [360.0, 600.0, 1200.0]) {
        for (final scale in const [1.0, 1.3, 2.0]) {
          for (final images in const [1, 4]) {
            testWidgets(
              '$images image(s), ${dark ? 'dark' : 'light'} ${width.toInt()}dp '
              'x$scale: chips inside their tiles, 48dp, sheet opens',
              (tester) async {
                tester.view.physicalSize = Size(width, 900);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.reset);
                final column = width < 632 ? width - 32 : 600.0;
                await tester.pumpWidget(
                  _host(
                    PostMedia(
                      media: [
                        for (var i = 0; i < images; i++) _ref(alt: 'image $i'),
                      ],
                    ),
                    width: column,
                    theme: dark ? appDarkTheme : appLightTheme,
                    textScale: scale,
                  ),
                );

                expect(mediaPageCount(tester), images == 1 ? isNull : images);
                expect(tester.takeException(), isNull);
                // Each tile's chip is inside its tile, 48dp, and the sheet
                // opens with that tile's description.
                for (var i = 0; i < images; i++) {
                  if (images > 1) await _reveal(tester, i);
                  final mine = _chipOf('image $i');
                  expect(mine, findsOneWidget);
                  final media = tester.getRect(_frameOf(mine));
                  final target = tester.getRect(
                    find
                        .descendant(
                          of: mine,
                          matching: find.byType(ConstrainedBox),
                        )
                        .first,
                  );
                  expect(target.width, greaterThanOrEqualTo(48));
                  expect(target.height, greaterThanOrEqualTo(48));
                  expect(target.left, greaterThanOrEqualTo(media.left - 1));
                  expect(target.right, lessThanOrEqualTo(media.right + 1));
                  expect(target.bottom, lessThanOrEqualTo(media.bottom + 1));

                  await tester.ensureVisible(mine);
                  await tester.pump();
                  await tester.tap(mine);
                  await tester.pumpAndSettle();
                  expect(find.byType(AltTextSheet), findsOneWidget);
                  expect(find.text('image $i'), findsOneWidget);
                  final sheet = tester.getRect(find.byType(AltTextSheet));
                  expect(sheet.width, lessThanOrEqualTo(width));
                  expect(tester.takeException(), isNull);
                  await tester.tapAt(const Offset(10, 10));
                  await tester.pumpAndSettle();
                  expect(find.byType(AltTextSheet), findsNothing);
                }
              },
            );
          }
        }
      }
    }
  });

  group('W2-13 inside a tappable card', () {
    testWidgets('the chip opens the sheet and does not trigger the '
        'card\'s own tap; the text beside it still does', (tester) async {
      var opened = 0;
      final view = pb.PostView(
        post: pb.Post(
          postId: '0108225137617092608',
          text: 'a post with a described image',
          author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
          media: [_ref(alt: 'a cat on a sofa')],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appDarkTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: InkWell(
                onTap: () => opened++,
                child: PostCard(view: view),
              ),
            ),
          ),
        ),
      );

      // The image spans the card's width, so the chip sits below the fold.
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(find.byType(AltTextSheet), findsOneWidget);
      expect(find.text('a cat on a sofa'), findsOneWidget);
      expect(opened, 0, reason: 'the chip wins the gesture');

      // Close the sheet, then a tap on the card text opens the post.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(AltTextSheet), findsNothing);
      await tester.tap(find.text('a post with a described image'));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });
  });
}
