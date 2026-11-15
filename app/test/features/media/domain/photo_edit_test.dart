import 'dart:typed_data';

import 'package:dzeroth/features/media/domain/image_preflight.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/photo_edit.dart';
import 'package:dzeroth/features/media/domain/raster_image_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../../../support/raster_fakes.dart';

/// Left half red, right half blue.
Uint8List _redBlue(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(0, 0, 255));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: w ~/ 2 - 1,
    y2: h - 1,
    color: img.ColorRgb8(255, 0, 0),
  );
  return Uint8List.fromList(img.encodePng(image));
}

bool _isRed(img.Pixel p) => p.r > 200 && p.b < 60;
bool _isBlue(img.Pixel p) => p.b > 200 && p.r < 60;

void _expectInside(CropFractions b) {
  expect(b.left, inInclusiveRange(0.0, 1.0));
  expect(b.top, inInclusiveRange(0.0, 1.0));
  expect(b.right, inInclusiveRange(0.0, 1.0));
  expect(b.bottom, inInclusiveRange(0.0, 1.0));
  expect(b.right - b.left, greaterThanOrEqualTo(kMinCropSide - 1e-9));
  expect(b.bottom - b.top, greaterThanOrEqualTo(kMinCropSide - 1e-9));
}

void main() {
  group('crop maths', () {
    test('rotatedSize swaps on odd turns', () {
      expect(rotatedSize(40, 20, 0), (width: 40, height: 20));
      expect(rotatedSize(40, 20, 1), (width: 20, height: 40));
      expect(rotatedSize(40, 20, 2), (width: 40, height: 20));
      expect(rotatedSize(40, 20, 3), (width: 20, height: 40));
    });

    test('editCropRect is integer, non-empty and inside the photo', () {
      expect(editCropRect(PhotoEdit.none, 40, 20), (
        x: 0,
        y: 0,
        width: 40,
        height: 20,
      ));
      const e = PhotoEdit(left: 0.25, top: 0.5, right: 0.75, bottom: 1);
      expect(editCropRect(e, 40, 20), (x: 10, y: 10, width: 20, height: 10));
      const sliver = PhotoEdit(left: 0.999, top: 0.999, right: 1, bottom: 1);
      final r = editCropRect(sliver, 10, 10);
      expect(r.width, greaterThanOrEqualTo(1));
      expect(r.height, greaterThanOrEqualTo(1));
      expect(r.x + r.width, lessThanOrEqualTo(10));
      expect(r.y + r.height, lessThanOrEqualTo(10));
    });

    test('presets: the biggest centred box of that shape', () {
      // A 4:3 landscape photo.
      const aspect = 4 / 3;
      final square = fitPreset(CropPreset.square.ratio, aspect);
      expect(square.right - square.left, closeTo(0.75, 1e-9));
      expect(square.bottom - square.top, 1);
      expect(square.left, closeTo(0.125, 1e-9));

      final wide = fitPreset(CropPreset.sixteenNine.ratio, aspect);
      expect(wide.right - wide.left, 1);
      expect((wide.bottom - wide.top) * 3 / 4, closeTo(9 / 16 * 1, 1e-9));
      // The pixel shape is the asked one: (w * 4) / (h * 3) = 16 / 9.
      expect(
        (wide.right - wide.left) * 4 / ((wide.bottom - wide.top) * 3),
        closeTo(16 / 9, 1e-9),
      );

      // 4:5 on a landscape photo is limited by the height.
      final portrait = fitPreset(CropPreset.fourFive.ratio, aspect);
      expect(portrait.bottom - portrait.top, 1);
      expect((portrait.right - portrait.left) * 4 / 3, closeTo(4 / 5, 1e-9));

      expect(fitPreset(CropPreset.original.ratio, aspect), kFullCrop);
    });

    test('a preset keeps the box near where it was', () {
      const left = (left: 0.0, top: 0.0, right: 0.2, bottom: 0.2);
      final box = fitPreset(1, 1, around: left);
      _expectInside(box);
      expect(box.left, 0);
    });

    test('moveCrop and zoomCrop never leave the photo', () {
      const box = (left: 0.2, top: 0.2, right: 0.6, bottom: 0.6);
      _expectInside(moveCrop(box, -5, 5));
      expect(moveCrop(box, -5, 0).left, 0);
      for (final f in [0.01, 0.5, 2.0, 50.0]) {
        _expectInside(zoomCrop(box, f));
      }
      final tiny = zoomCrop(box, 0.0001);
      expect(tiny.right - tiny.left, closeTo(kMinCropSide, 1e-9));
    });

    test('dragHandle: free and ratio-locked, extreme drags stay inside', () {
      const box = (left: 0.2, top: 0.2, right: 0.8, bottom: 0.8);
      for (final handle in CropHandle.values) {
        for (final d in [-3.0, -0.3, 0.0, 0.3, 3.0]) {
          for (final e in [-3.0, 0.0, 3.0]) {
            _expectInside(dragHandle(box, handle, d, e));
            _expectInside(
              dragHandle(box, handle, d, e, ratio: 16 / 9, photoAspect: 4 / 3),
            );
          }
        }
      }
      // Free: only the dragged corner moves.
      final free = dragHandle(box, CropHandle.bottomRight, -0.1, 0.1);
      expect(free.left, 0.2);
      expect(free.top, 0.2);
      expect(free.right, closeTo(0.7, 1e-9));
      expect(free.bottom, closeTo(0.9, 1e-9));
      // Locked square on a square photo: the shape holds.
      final locked = dragHandle(
        box,
        CropHandle.bottomRight,
        -0.2,
        0.0,
        ratio: 1,
        photoAspect: 1,
      );
      expect(
        locked.right - locked.left,
        closeTo(locked.bottom - locked.top, 1e-9),
      );
    });

    test('rotated() turns once and starts the crop over', () {
      const e = PhotoEdit(quarterTurns: 3, left: 0.1, right: 0.9);
      final next = e.rotated();
      expect(next.quarterTurns, 0);
      expect(next.hasCrop, isFalse);
      expect(PhotoEdit.none.isIdentity, isTrue);
      expect(const PhotoEdit(quarterTurns: 1).isIdentity, isFalse);
    });
  });

  group('package:image path (isolate processor core)', () {
    test('rotate 90 turns clockwise and declares the rotated size', () {
      final out = processImageSync(
        _redBlue(40, 20),
        ImagePurpose.post,
        edit: const PhotoEdit(quarterTurns: 1),
      );
      expect((out.width, out.height), (20, 40));
      expect(jpegDims(out.fullBytes), (width: 20, height: 40));
      final decoded = img.decodeJpg(out.fullBytes)!;
      // Left half (red) goes to the top.
      expect(_isRed(decoded.getPixel(10, 5)), isTrue);
      expect(_isBlue(decoded.getPixel(10, 35)), isTrue);
    });

    test('crop is taken from the rotated photo; dims match the JPEG', () {
      // Rotated photo is 20 x 40 (red top half); keep its lower half.
      final out = processImageSync(
        _redBlue(40, 20),
        ImagePurpose.post,
        edit: const PhotoEdit(quarterTurns: 1, top: 0.5),
      );
      expect((out.width, out.height), (20, 20));
      expect(jpegDims(out.fullBytes), (width: 20, height: 20));
      expect(jpegDims(out.thumbBytes), (width: 20, height: 20));
      expect(_isBlue(img.decodeJpg(out.fullBytes)!.getPixel(10, 10)), isTrue);
    });

    test('presets crop to the asked shape on the encoded JPEG', () {
      for (final preset in CropPreset.values) {
        const w = 120, h = 90;
        final box = fitPreset(preset.ratio, w / h);
        final out = processImageSync(
          _redBlue(w, h),
          ImagePurpose.post,
          edit: const PhotoEdit().withBox(box),
        );
        final dims = jpegDims(out.fullBytes)!;
        expect((out.width, out.height), (dims.width, dims.height));
        final ratio = preset.ratio ?? w / h;
        expect(
          out.width / out.height,
          closeTo(ratio, 0.03),
          reason: preset.label,
        );
      }
    });

    test('an identity edit equals no edit; avatars ignore the edit', () {
      final src = _redBlue(40, 20);
      final a = processImageSync(src, ImagePurpose.post);
      final b = processImageSync(src, ImagePurpose.post, edit: PhotoEdit.none);
      expect(b.fullBytes, a.fullBytes);
      final avatar = processImageSync(
        src,
        ImagePurpose.avatar,
        edit: const PhotoEdit(quarterTurns: 1, left: 0.5),
      );
      expect((avatar.width, avatar.height), (20, 20));
    });
  });

  group('web worker path (RasterImageProcessor)', () {
    final input = fakeJpeg(4000, 3000, padding: 64);

    test(
      'crop is in the rotated frame, turns go to the worker, dims match',
      () async {
        final codec = FakeRasterCodec();
        const edit = PhotoEdit(quarterTurns: 1, top: 0.25, bottom: 0.75);
        final out = await RasterImageProcessor(codec)
            .process(input, ImagePurpose.post, edit: edit);
        // Rotated photo is 3000 x 4000; the crop is 3000 x 2000.
        expect(codec.encodes.first.crop, (
          x: 0,
          y: 1000,
          width: 3000,
          height: 2000,
        ));
        expect(codec.turns, everyElement(1));
        expect((out.width, out.height), (2048, 1365));
        // The processor itself checks the SOF of every JPEG; so does this.
        expect(jpegDims(out.fullBytes), (width: 2048, height: 1365));
        expect(jpegDims(out.thumbBytes), (width: 1080, height: 720));
        expect(codec.rgbaCalls.single, (width: 32, height: 21));
      },
    );

    test('no edit keeps the whole photo with no turns', () async {
      final codec = FakeRasterCodec();
      await RasterImageProcessor(codec).process(input, ImagePurpose.post);
      expect(codec.encodes.first.crop, (x: 0, y: 0, width: 4000, height: 3000));
      expect(codec.turns, everyElement(0));
    });

    test('both paths pick the same crop pixels for the same edit', () {
      const edit = PhotoEdit(quarterTurns: 3, left: 0.1, top: 0.2, right: 0.9);
      final rotated = rotatedSize(40, 20, edit.quarterTurns);
      final rect = editCropRect(edit, rotated.width, rotated.height);
      final out = processImageSync(
        _redBlue(40, 20),
        ImagePurpose.post,
        edit: edit,
      );
      expect((out.width, out.height), (rect.width, rect.height));
    });
  });
}
