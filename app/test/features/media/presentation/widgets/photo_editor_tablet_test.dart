import 'dart:typed_data';

import 'package:dzeroth/features/media/presentation/widgets/photo_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../../../support/tablet_modal_harness.dart';

/// On the tablet and desktop layouts the editor is a dialog (the app's sheet
/// mapping), not a bottom sheet.
void main() {
  final photo = Uint8List.fromList(
    img.encodePng(img.Image(width: 80, height: 60)),
  );
  PhotoEditResult? result;
  var closed = false;

  Future<void> open(
    WidgetTester tester, {
    required double width,
    required double height,
    double textScale = 1,
  }) async {
    result = null;
    closed = false;
    await pumpTabletModalHost(
      tester,
      width: width,
      height: height,
      textScale: textScale,
      trigger: (context) => TextButton(
        onPressed: () async {
          result = await showPhotoEditor(
            context,
            source: photo,
            preview: photo,
          );
          closed = true;
        },
        child: const Text('open'),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  for (final (w, h, scale) in [
    (834.0, 1194.0, 1.0),
    (834.0, 1194.0, 2.0),
    (600.0, 800.0, 2.0),
    (1440.0, 900.0, 1.0),
    (1440.0, 900.0, 2.0),
  ]) {
    testWidgets('dialog at ${w.toInt()} x ${h.toInt()}, ${scale}x text', (
      tester,
    ) async {
      await open(tester, width: w, height: h, textScale: scale);
      expect(tester.takeException(), isNull);
      // A dialog over the page, not a bottom sheet.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(PhotoEditorView), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Rotate'), findsOneWidget);
      await tester.ensureVisible(find.byType(TextField));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(find.byType(PhotoEditorView));
      expect(dialog.bottom, lessThanOrEqualTo(h));
      expect(dialog.right, lessThanOrEqualTo(w));

      // The controls scroll; the user scrolls to the chip.
      await tester.ensureVisible(find.text('Square'));
      await tester.pump();
      await tester.tap(find.text('Square'));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result!.edit.hasCrop, isTrue);
    });
  }
}
