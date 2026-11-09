import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';

/// D02: a photo removed while it is prepared (or a composer closed with
/// photos still queued) stops its work: the in-flight job is cancelled and
/// queued ones never start.
void main() {
  setUpAll(registerMediaFallbacks);

  late FakeImageProcessor processor;

  AttachmentsCubit build() => AttachmentsCubit(
    picker: FakeImagePicker(),
    processor: processor,
    uploader: MediaUploader(repository: MockMediaRepository()),
  );

  setUp(() => processor = FakeImageProcessor(gated: true));

  List<AttachmentStatus> statuses(AttachmentsState s) => [
    for (final a in s.items) a.status,
  ];

  blocTest<AttachmentsCubit, AttachmentsState>(
    'removing the photo being prepared cancels it; the next one proceeds',
    build: build,
    act: (cubit) async {
      final adding = cubit.addImages([imageBytes('a'), imageBytes('b')]);
      await pumpEventQueue();
      expect(processor.waiting, 1);
      final first = cubit.state.items.first.id;
      cubit.remove(first);
      expect(processor.cancellations.single!.isCancelled, isTrue);
      await pumpEventQueue();
      // The second photo starts only after the first was dropped.
      expect(processor.inputs, hasLength(2));
      processor.release();
      await adding;
    },
    verify: (cubit) {
      expect(statuses(cubit.state), [AttachmentStatus.ready]);
      expect(cubit.state.items.single.image!.fullMd5, 'full-b');
      expect(processor.cancellations.last!.isCancelled, isFalse);
    },
  );

  blocTest<AttachmentsCubit, AttachmentsState>(
    'a queued photo removed before its turn is never processed',
    build: build,
    act: (cubit) async {
      final adding = cubit.addImages([
        imageBytes('a'),
        imageBytes('b'),
        imageBytes('c'),
      ]);
      await pumpEventQueue();
      cubit.remove(cubit.state.items[1].id); // 'b', still queued
      processor.release(); // 'a'
      await pumpEventQueue();
      processor.release(); // 'c'
      await adding;
    },
    verify: (cubit) {
      expect(processor.inputs.map((b) => String.fromCharCode(b.first)), [
        'a',
        'c',
      ]);
      expect(statuses(cubit.state), [
        AttachmentStatus.ready,
        AttachmentStatus.ready,
      ]);
    },
  );

  test('closing the composer cancels the photo in flight and skips the '
      'queued ones', () async {
    final cubit = build();
    final adding = cubit.addImages([
      imageBytes('a'),
      imageBytes('b'),
      imageBytes('c'),
    ]);
    await pumpEventQueue();
    expect(processor.waiting, 1);
    await cubit.close();
    await adding;
    expect(processor.cancellations.single!.isCancelled, isTrue);
    expect(processor.inputs, hasLength(1));
  });

  test('clear() also cancels work in flight', () async {
    final cubit = build();
    final adding = cubit.addImages([imageBytes('a')]);
    await pumpEventQueue();
    cubit.clear();
    await adding;
    expect(processor.cancellations.single!.isCancelled, isTrue);
    expect(cubit.state.isEmpty, isTrue);
    await cubit.close();
  });

  blocTest<AttachmentsCubit, AttachmentsState>(
    'tiles stay "processing" (the spinner) until their job finishes',
    build: build,
    act: (cubit) async {
      final adding = cubit.addImages([imageBytes('a'), imageBytes('b')]);
      await pumpEventQueue();
      expect(statuses(cubit.state), [
        AttachmentStatus.processing,
        AttachmentStatus.processing,
      ]);
      processor.release();
      await pumpEventQueue();
      expect(statuses(cubit.state), [
        AttachmentStatus.ready,
        AttachmentStatus.processing,
      ]);
      processor.release();
      await adding;
    },
    verify: (cubit) => expect(statuses(cubit.state), [
      AttachmentStatus.ready,
      AttachmentStatus.ready,
    ]),
  );
}
