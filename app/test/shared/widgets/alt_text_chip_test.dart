import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/alt_text_chip.dart';
import 'package:dzeroth/shared/widgets/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  final chip = find.byType(AltTextChip);

  testWidgets('no chip on an image without a description', (tester) async {
    await tester.pumpWidget(_host(PostMedia(media: [_ref(), _ref()])));
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
          ],
        ),
      ),
    );
    expect(chip, findsOneWidget);
    expect(find.text('ALT'), findsOneWidget);
  });

  testWidgets('the chip is bottom-start of its tile with a 48dp target', (
    tester,
  ) async {
    await tester.pumpWidget(_host(PostMedia(media: [_ref(alt: 'a cat')])));
    final media = tester.getRect(find.byType(AspectRatio));
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
    final media = tester.getRect(find.byType(AspectRatio));
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
          expect(chip, findsNWidgets(4));
          expect(tester.takeException(), isNull);

          await tester.tap(chip.first);
          await tester.pumpAndSettle();
          expect(find.byType(AltTextSheet), findsOneWidget);
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
}
