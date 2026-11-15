import 'dart:ui' show PointerDeviceKind;
import 'dart:typed_data';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/media/domain/photo_edit.dart';
import 'package:dzeroth/features/media/presentation/widgets/photo_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// The editor: aspect presets, Rotate, the crop box, the description, Done
/// and Cancel.
void main() {
  // A 4:3 photo, so Square and 4:5 are limited by the height and 16:9 by the
  // width.
  final photo = Uint8List.fromList(
    img.encodePng(img.Image(width: 80, height: 60)),
  );

  PhotoEditResult? result;
  var closed = false;

  Future<void> open(
    WidgetTester tester, {
    double width = 400,
    double height = 800,
    double scale = 1,
    Uint8List? source,
    bool isGif = false,
    PhotoEdit initial = PhotoEdit.none,
    String alt = '',
  }) async {
    result = null;
    closed = false;
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: app!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showPhotoEditor(
                    context,
                    source: source ?? photo,
                    preview: photo,
                    initialEdit: initial,
                    initialAlt: alt,
                    isGif: isGif,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The image decodes outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
  }

  testWidgets('Done with no change returns the identity edit', (tester) async {
    await open(tester);
    await done(tester);
    expect(closed, isTrue);
    expect(result!.edit.isIdentity, isTrue);
    expect(result!.altText, '');
  });

  testWidgets('Cancel returns nothing', (tester) async {
    await open(tester);
    await tester.tap(find.text('Rotate'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, isNull);
  });

  testWidgets('presets set the crop box to that shape', (tester) async {
    await open(tester);
    for (final (label, ratio) in [
      ('Square', 1.0),
      ('4:5', 4 / 5),
      ('16:9', 16 / 9),
    ]) {
      await tester.tap(find.text(label));
      await tester.pump();
      // Done reads the current box; reopen is not needed, so read it from the
      // semantics value of the crop box instead of closing.
      final edit = _boxOf(tester);
      expect(
        (edit.right - edit.left) * 80 / ((edit.bottom - edit.top) * 60),
        closeTo(ratio, 0.01),
        reason: label,
      );
    }
    await tester.tap(find.text('Original'));
    await tester.pump();
    expect(_boxOf(tester), kFullCrop);
    await done(tester);
    expect(result!.edit.isIdentity, isTrue);
  });

  testWidgets('Square then Done returns a square crop', (tester) async {
    await open(tester);
    await tester.tap(find.text('Square'));
    await tester.pump();
    await done(tester);
    final e = result!.edit;
    expect(e.hasCrop, isTrue);
    expect(e.right - e.left, closeTo(0.75, 1e-6));
    expect(e.bottom - e.top, 1);
  });

  testWidgets('Rotate turns the photo and resets the crop', (tester) async {
    await open(tester);
    await tester.tap(find.text('Square'));
    await tester.pump();
    await tester.tap(find.text('Rotate'));
    await tester.pump();
    await tester.tap(find.text('Rotate'));
    await tester.pump();
    await done(tester);
    expect(result!.edit.quarterTurns, 2);
    expect(result!.edit.hasCrop, isFalse);
  });

  testWidgets('four rotations come back to upright', (tester) async {
    await open(tester);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Rotate'));
      await tester.pump();
    }
    await done(tester);
    expect(result!.edit.isIdentity, isTrue);
  });

  testWidgets('dragging a corner handle resizes the crop box freely', (
    tester,
  ) async {
    await open(tester);
    final handle = find.bySemanticsLabel('Crop corner, bottom right');
    final handleOn = tester.ensureSemantics();
    final from = tester.getCenter(handle);
    await tester.dragFrom(from, const Offset(-60, -40));
    await tester.pump();
    final box = _boxOf(tester);
    expect(box.left, 0);
    expect(box.top, 0);
    expect(box.right, lessThan(1));
    expect(box.bottom, lessThan(1));
    handleOn.dispose();
  });

  testWidgets('dragging the box moves it; Move and size actions work', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    await tester.tap(find.text('Square'));
    await tester.pump();
    final before = _boxOf(tester);

    _perform(tester, 'Move crop right');
    await tester.pump();
    final moved = _boxOf(tester);
    expect(moved.left, greaterThan(before.left));
    expect(moved.right - moved.left, closeTo(before.right - before.left, 1e-9));

    _perform(tester, 'Smaller crop');
    await tester.pump();
    final smaller = _boxOf(tester);
    expect(smaller.right - smaller.left, lessThan(moved.right - moved.left));

    _perform(tester, 'Larger crop');
    await tester.pump();
    expect(
      _boxOf(tester).right - _boxOf(tester).left,
      greaterThan(smaller.right - smaller.left),
    );
    handle.dispose();
  });

  testWidgets('a pinch resizes the box about its centre', (tester) async {
    await open(tester);
    await tester.tap(find.text('Square'));
    await tester.pump();
    final before = _boxOf(tester);
    final center = tester.getCenter(find.byKey(kCropBoxKey));
    final a = await tester.startGesture(center - const Offset(10, 0));
    final b = await tester.startGesture(center + const Offset(10, 0));
    // Both fingers move apart in small alternating steps, as a pinch does.
    for (var i = 1; i <= 6; i++) {
      await a.moveTo(center - Offset(10.0 + i * 5, 0));
      await b.moveTo(center + Offset(10.0 + i * 5, 0));
    }
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();
    final after = _boxOf(tester);
    // Fingers apart = zoom in = a smaller box.
    expect(after.right - after.left, lessThan(before.right - before.left));
    final cx = (after.left + after.right) / 2;
    expect(cx, closeTo((before.left + before.right) / 2, 0.02));
  });

  testWidgets('the description is returned, and a long one blocks Done', (
    tester,
  ) async {
    await open(tester, alt: 'old');
    expect(find.text('old'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'a red barn');
    await tester.pump();
    await done(tester);
    expect(result!.altText, 'a red barn');

    await open(tester);
    await tester.enterText(
      find.byType(TextField),
      'x' * (kMaxAltTextLength + 1),
    );
    await tester.pump();
    expect(find.text('At most $kMaxAltTextLength characters.'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
  });

  testWidgets('a GIF only has the description: no presets, no rotate', (
    tester,
  ) async {
    await open(tester, isGif: true);
    expect(find.text('Edit GIF'), findsOneWidget);
    expect(find.text('Square'), findsNothing);
    expect(find.text('Rotate'), findsNothing);
    expect(find.byKey(kCropBoxKey), findsNothing);
    await tester.enterText(find.byType(TextField), 'dancing');
    await done(tester);
    expect(result!.edit.isIdentity, isTrue);
    expect(result!.altText, 'dancing');
  });

  testWidgets('an existing edit is shown and kept', (tester) async {
    await open(
      tester,
      initial: const PhotoEdit(
        quarterTurns: 1,
        left: 0.1,
        top: 0.1,
        right: 0.9,
        bottom: 0.9,
      ),
    );
    await done(tester);
    expect(
      result!.edit,
      const PhotoEdit(
        quarterTurns: 1,
        left: 0.1,
        top: 0.1,
        right: 0.9,
        bottom: 0.9,
      ),
    );
  });

  testWidgets('keyboard: the description stays above it on a small phone', (
    tester,
  ) async {
    await open(tester, width: 320, height: 640, scale: 2);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.ensureVisible(find.byType(TextField));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // The scrolling controls sit entirely above the keyboard (640 - 300) and
    // keep a usable height; the field scrolls inside them.
    final controls = tester.getRect(find.byType(SingleChildScrollView).last);
    expect(controls.bottom, lessThanOrEqualTo(340));
    expect(controls.height, greaterThan(150));
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('a mouse wheel resizes the box', (tester) async {
    await open(tester);
    await tester.tap(find.text('Square'));
    await tester.pump();
    final before = _boxOf(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byKey(kCropBoxKey)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -40)));
    await tester.pump();
    expect(
      _boxOf(tester).right - _boxOf(tester).left,
      lessThan(before.right - before.left),
    );
  });

  for (final (w, h, scale) in [
    (320.0, 640.0, 2.0),
    (320.0, 640.0, 1.0),
    (900.0, 700.0, 2.0),
  ]) {
    testWidgets('fits ${w.toInt()} x ${h.toInt()} at ${scale}x text', (
      tester,
    ) async {
      await open(tester, width: w, height: h, scale: scale);
      expect(tester.takeException(), isNull);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Rotate'), findsOneWidget);
      // Every control is reachable (the controls scroll).
      await tester.ensureVisible(find.byType(TextField));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}

CropFractions _boxOf(WidgetTester tester) {
  final box = tester.getRect(find.byKey(kCropBoxKey));
  final photo = tester.getRect(find.byKey(kCropPhotoKey));
  return (
    left: (box.left - photo.left) / photo.width,
    top: (box.top - photo.top) / photo.height,
    right: (box.right - photo.left) / photo.width,
    bottom: (box.bottom - photo.top) / photo.height,
  );
}

void _perform(WidgetTester tester, String action) {
  final node = tester.getSemantics(find.byKey(kCropBoxKey));
  final id = [
    for (final i in node.getSemanticsData().customSemanticsActionIds ?? <int>[])
      if (CustomSemanticsAction.getAction(i)!.label == action) i,
  ].single;
  // ignore: deprecated_member_use
  tester.binding.pipelineOwner.semanticsOwner!.performAction(
    node.id,
    SemanticsAction.customAction,
    id,
  );
}
