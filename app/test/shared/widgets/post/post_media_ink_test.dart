import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/post/post_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

/// Regression (T8c review, assigned to R1): the image painted over its
/// InkWell, whose ink (ripple, hover and the keyboard focus highlight) is
/// drawn on the nearest Material below it, the page's. The InkWell now sits
/// on its own transparent Material above the image.
void main() {
  common.MediaRef photo({String alt = ''}) =>
      common.MediaRef(mediaId: 'm1', width: 1600, height: 900, altText: alt);

  Future<void> pump(
    WidgetTester tester, {
    String alt = '',
    ValueChanged<int>? onOpen,
  }) => pumpThemed(
    tester,
    Center(
      child: SizedBox(
        width: 320,
        child: PostMedia(
          media: [photo(alt: alt)],
          onOpenImage: onOpen ?? (_) {},
        ),
      ),
    ),
  );

  Finder inkWellInMedia() => find.descendant(
    of: find.byType(PostMedia),
    matching: find.byType(InkWell),
  );

  testWidgets('the ink is drawn on a transparent Material above the image', (
    tester,
  ) async {
    await pump(tester);

    expect(inkWellInMedia(), findsOneWidget);
    final inkElement = tester.element(inkWellInMedia());
    // The Material the ink paints on: the nearest one above the InkWell.
    final material = inkElement.findAncestorWidgetOfExactType<Material>()!;
    expect(material.type, MaterialType.transparency);
    final materialElement = find.byWidget(material);
    expect(
      find.descendant(of: find.byType(PostMedia), matching: materialElement),
      findsOneWidget,
      reason: 'the ink Material belongs to the media tile, not the page',
    );
    // The overlay covers the whole tile, so the ripple and focus ring do.
    expect(
      tester.getRect(inkWellInMedia()),
      tester.getRect(
        find.descendant(
          of: find.byType(PostMedia),
          matching: find.byType(AspectRatio),
        ),
      ),
    );
  });

  testWidgets('keyboard focus reaches the image and Enter opens it', (
    tester,
  ) async {
    var opened = -1;
    await pump(tester, onOpen: (i) => opened = i);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(
      focused!.findAncestorWidgetOfExactType<PostMedia>(),
      isNotNull,
      reason: 'Tab lands on the image',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 0);
  });

  testWidgets('one "Open image" button and one image node with the alt text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, alt: 'A dog');

    expect(find.bySemanticsLabel('Open image'), findsOneWidget);
    expect(find.bySemanticsLabel('A dog'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Open image')),
      isSemantics(isButton: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('A dog')),
      isSemantics(isImage: true, isButton: false),
    );
    handle.dispose();
  });
}
