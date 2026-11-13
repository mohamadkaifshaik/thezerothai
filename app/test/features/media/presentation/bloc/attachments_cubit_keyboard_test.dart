import 'dart:typed_data';

import 'package:dzeroth/features/media/data/media_uploader.dart';
import 'package:dzeroth/features/media/presentation/bloc/attachments_cubit.dart';
import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/media_fixtures.dart';

/// Content a keyboard inserts (Gboard's GIF tab), and a lone gallery GIF.
void main() {
  setUpAll(registerMediaFallbacks);

  late MockMediaRepository repo;
  late FakeImagePicker picker;
  late FakeGifPreparer preparer;
  late AttachmentsCubit cubit;

  AttachmentsCubit build({bool gifEnabled = true}) => AttachmentsCubit(
    picker: picker,
    processor: FakeImageProcessor(),
    uploader: MediaUploader(repository: repo),
    gifSource: FakeGifSource(),
    gifPreparer: preparer,
    gifEnabled: gifEnabled,
  );

  setUp(() {
    repo = MockMediaRepository();
    picker = FakeImagePicker();
    preparer = FakeGifPreparer();
    cubit = build();
  });

  tearDown(() => cubit.close());

  final gifBytes = Uint8List.fromList([...'GIF89a'.codeUnits, 1, 2, 3]);

  const on = ComposerAttachmentRules(
    flagPolls: false,
    engagementOn: false,
    flagGif: true,
    mediaOn: true,
  );
  const gifOff = ComposerAttachmentRules(
    flagPolls: false,
    engagementOn: false,
    flagGif: false,
    mediaOn: true,
  );

  test('a keyboard GIF becomes a ready GIF attachment', () async {
    await cubit.insertContent(
      mimeType: 'image/gif',
      bytes: gifBytes,
      rules: on,
    );
    final a = cubit.state.items.single;
    expect(a.isGif, isTrue);
    expect(a.status, AttachmentStatus.ready);
    expect(cubit.state.refusal, isNull);
  });

  test('with the GIF flag off a keyboard GIF is refused, not attached', () async {
    await cubit.insertContent(
      mimeType: 'image/gif',
      bytes: gifBytes,
      rules: gifOff,
    );
    expect(cubit.state.isEmpty, isTrue);
    expect(cubit.state.refusal, kGifOffMessage);
  });

  test('a keyboard GIF over photos says what the GIF button would', () async {
    picker.next = [imageBytes('p')];
    await cubit.pick();
    await cubit.insertContent(
      mimeType: 'image/gif',
      bytes: gifBytes,
      rules: const ComposerAttachmentRules(
        flagPolls: false,
        engagementOn: false,
        flagGif: true,
        mediaOn: true,
        hasPhotos: true,
      ),
    );
    expect(cubit.state.photoCount, 1);
    expect(cubit.state.hasGif, isFalse);
    expect(cubit.state.refusal, "A GIF can't be added to photos");
  });

  test('a keyboard PNG becomes a photo', () async {
    await cubit.insertContent(
      mimeType: 'image/png',
      bytes: imageBytes('s'),
      rules: on,
    );
    expect(cubit.state.photoCount, 1);
    expect(cubit.state.hasGif, isFalse);
  });

  test('an unsupported type is ignored', () async {
    await cubit.insertContent(
      mimeType: 'video/mp4',
      bytes: imageBytes('v'),
      rules: on,
    );
    await cubit.insertContent(
      mimeType: 'image/heic',
      bytes: imageBytes('h'),
      rules: on,
    );
    expect(cubit.state.isEmpty, isTrue);
    expect(cubit.state.refusal, isNull);
  });

  test('a lone gallery GIF stays a GIF when GIFs are on', () async {
    picker.next = [gifBytes];
    await cubit.pick();
    expect(cubit.state.hasGif, isTrue);
  });

  test('with GIFs off a gallery GIF is processed as a photo, as before', () async {
    final off = build(gifEnabled: false);
    addTearDown(off.close);
    picker.next = [gifBytes];
    await off.pick();
    expect(off.state.hasGif, isFalse);
    expect(off.state.photoCount, 1);
  });
}
