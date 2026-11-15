import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/domain/photo_edit.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/media_fixtures.dart';

/// Reorder, and the editor's Done: alt text plus a reprocess of the SOURCE.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImagePicker picker;
  late FakeImageProcessor processor;
  late AttachmentsCubit cubit;

  setUp(() {
    repo = MockMediaRepository();
    picker = FakeImagePicker();
    processor = FakeImageProcessor();
    cubit = AttachmentsCubit(
      picker: picker,
      processor: processor,
      uploader: MediaUploader(repository: repo),
    );
  });

  tearDown(() => cubit.close());

  Future<void> addPhotos(List<String> tags) async {
    picker.next = [for (final t in tags) imageBytes(t)];
    await cubit.pick();
  }

  List<String> md5s() => [for (final a in cubit.state.items) a.image!.fullMd5];

  group('reorder', () {
    test('moves a photo to its new index', () async {
      await addPhotos(['a', 'b', 'c']);
      final before = md5s();
      cubit.reorder(0, 2);
      expect(md5s(), [before[1], before[2], before[0]]);
      cubit.reorder(2, 0);
      expect(md5s(), before);
    });

    test('out of range or unchanged does nothing', () async {
      await addPhotos(['a', 'b']);
      final items = cubit.state.items;
      cubit.reorder(0, 0);
      cubit.reorder(-1, 1);
      cubit.reorder(0, 2);
      expect(identical(cubit.state.items, items), isTrue);
    });

    test('move steps one place and stops at the ends', () async {
      await addPhotos(['a', 'b', 'c']);
      final ids = [for (final a in cubit.state.items) a.id];
      cubit.move(ids[0], -1);
      expect([for (final a in cubit.state.items) a.id], ids);
      cubit.move(ids[0], 1);
      expect(
        [for (final a in cubit.state.items) a.id],
        [ids[1], ids[0], ids[2]],
      );
    });

    test('the upload goes out in the new order', () async {
      stubHappyUpload(repo);
      await addPhotos(['a', 'b', 'c']);
      final ids = [for (final a in cubit.state.items) a.id];
      cubit.setAltText(ids[0], 'first');
      cubit.reorder(0, 2);
      final result = await cubit.uploadAll();
      // Reservations are made in picture order, so m1 is the first picture.
      expect(result.mediaIds, ['m1', 'm2', 'm3']);
      expect(result.altTexts, ['', '', 'first']);
      final sent =
          verify(
                () => repo.createUpload(
                  idempotencyKey: any(named: 'idempotencyKey'),
                  purpose: any(named: 'purpose'),
                  images: captureAny(named: 'images'),
                ),
              ).captured.single
              as List;
      expect([for (final i in sent) i.fullMd5], ['full-b', 'full-c', 'full-a']);
    });
  });

  group('applyEdit', () {
    const rotate = PhotoEdit(quarterTurns: 1);

    test(
      'sets the alt text and reprocesses the source with the edit',
      () async {
        await addPhotos(['a']);
        final id = cubit.state.items.single.id;
        expect(cubit.sourceOf(id), imageBytes('a'));
        expect(processor.edits, [null]);

        cubit.applyEdit(id, rotate, '  a cat  ');
        expect(cubit.state.items.single.status, AttachmentStatus.processing);
        await pumpEventQueue();

        final item = cubit.state.items.single;
        expect(item.status, AttachmentStatus.ready);
        expect(item.altText, 'a cat');
        expect(cubit.editOf(id), rotate);
        // The SOURCE bytes went in again, with the edit.
        expect(processor.inputs, [imageBytes('a'), imageBytes('a')]);
        expect(processor.edits, [null, rotate]);
      },
    );

    test('alt text alone does not reprocess', () async {
      await addPhotos(['a']);
      final id = cubit.state.items.single.id;
      cubit.applyEdit(id, PhotoEdit.none, 'only text');
      await pumpEventQueue();
      expect(cubit.state.items.single.altText, 'only text');
      expect(cubit.state.items.single.status, AttachmentStatus.ready);
      expect(processor.inputs, hasLength(1));
    });

    test(
      'an edit after the upload drops the stale upload and uploads again',
      () async {
        stubHappyUpload(repo);
        await addPhotos(['a']);
        final id = cubit.state.items.single.id;
        final first = await cubit.uploadAll();
        expect(first.mediaIds, ['m1']);
        expect(cubit.state.items.single.status, AttachmentStatus.uploaded);

        cubit.applyEdit(id, rotate, '');
        // Not published any more: the old media id is gone.
        expect(cubit.state.items.single.mediaId, '');
        await pumpEventQueue();
        expect(cubit.state.items.single.status, AttachmentStatus.ready);

        final second = await cubit.uploadAll();
        expect(second.mediaIds, ['m2']);
        verify(
          () => repo.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).called(2);
      },
    );

    test('a re-upload after an edit uses fresh idempotency keys, and only '
        'the edited photo is reserved', () async {
      stubHappyUpload(repo);
      await addPhotos(['a', 'b', 'c']);
      final id = cubit.state.items[1].id;
      await cubit.uploadAll();
      cubit.applyEdit(id, rotate, '');
      await pumpEventQueue();
      await cubit.uploadAll();

      final create = verify(
        () => repo.createUpload(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: captureAny(named: 'images'),
        ),
      ).captured;
      // [key1, images1, key2, images2]
      expect(create, hasLength(4));
      expect(create[0], isNot(create[2]));
      expect((create[1] as List), hasLength(3));
      expect((create[3] as List), hasLength(1));
      final finalizeKeys = verify(
        () => repo.finalizeUpload(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          items: any(named: 'items'),
        ),
      ).captured;
      expect(finalizeKeys, hasLength(2));
      expect(finalizeKeys[0], isNot(finalizeKeys[1]));
    });

    test('editing back to the original after an upload still mints a new '
        'create key (the old answer is for other pixels)', () async {
      stubHappyUpload(repo);
      await addPhotos(['a']);
      final id = cubit.state.items.single.id;
      await cubit.uploadAll();
      cubit.applyEdit(id, rotate, '');
      await pumpEventQueue();
      await cubit.uploadAll();
      cubit.applyEdit(id, PhotoEdit.none, '');
      await pumpEventQueue();
      await cubit.uploadAll();
      final keys = verify(
        () => repo.createUpload(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      ).captured;
      expect(keys.toSet(), hasLength(3));
    });

    test('previewOf keeps the unedited photo for the editor', () async {
      await addPhotos(['a']);
      final id = cubit.state.items.single.id;
      final first = cubit.previewOf(id);
      expect(first, isNotNull);
      cubit.applyEdit(id, rotate, '');
      await pumpEventQueue();
      // The edited result does not replace what the editor crops.
      expect(cubit.previewOf(id), first);
      cubit.remove(id);
      expect(cubit.previewOf(id), isNull);
    });

    test('an edit while processing cancels the old work', () async {
      final gated = FakeImageProcessor(gated: true);
      final c = AttachmentsCubit(
        picker: picker,
        processor: gated,
        uploader: MediaUploader(repository: repo),
      );
      addTearDown(c.close);
      picker.next = [imageBytes('a')];
      final picking = c.pick();
      await pumpEventQueue();
      final id = c.state.items.single.id;
      expect(c.state.items.single.status, AttachmentStatus.processing);

      // Not editable yet (no image), but a second apply while the first
      // reprocess runs supersedes it.
      gated.release();
      await picking;
      c.applyEdit(id, rotate, '');
      await pumpEventQueue();
      expect(gated.waiting, 1);
      c.applyEdit(id, const PhotoEdit(quarterTurns: 2), '');
      await pumpEventQueue();
      expect(gated.cancellations[1]!.isCancelled, isTrue);
      expect(gated.waiting, 1);
      gated.release();
      await pumpEventQueue();
      expect(c.state.items.single.status, AttachmentStatus.ready);
      expect(c.editOf(id).quarterTurns, 2);
    });

    test('a removed photo forgets its source and edit', () async {
      await addPhotos(['a']);
      final id = cubit.state.items.single.id;
      cubit.applyEdit(id, rotate, '');
      await pumpEventQueue();
      cubit.remove(id);
      expect(cubit.sourceOf(id), isNull);
      expect(cubit.editOf(id), PhotoEdit.none);
    });

    test('a GIF only takes the alt text', () async {
      final gifs = FakeGifSource();
      final c = AttachmentsCubit(
        picker: picker,
        processor: processor,
        uploader: MediaUploader(repository: repo),
        gifSource: gifs,
        gifPreparer: FakeGifPreparer(),
      );
      addTearDown(c.close);
      gifs.next = imageBytes('g');
      await c.pickGif();
      final id = c.state.items.single.id;
      c.applyEdit(id, rotate, 'dancing');
      await pumpEventQueue();
      expect(c.state.items.single.altText, 'dancing');
      expect(c.state.items.single.status, AttachmentStatus.ready);
      expect(c.editOf(id), PhotoEdit.none);
    });

    test('retain keeps sources for a reclaimed composer', () async {
      await addPhotos(['a']);
      final id = cubit.state.items.single.id;
      cubit.retain();
      await cubit.close();
      expect(cubit.isClosed, isFalse);
      expect(cubit.sourceOf(id), isNotNull);
      cubit.reclaim();
      cubit.applyEdit(id, rotate, '');
      await pumpEventQueue();
      expect(processor.edits.last, rotate);
    });
  });
}
