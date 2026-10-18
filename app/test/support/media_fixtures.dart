import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/features/media/data/image_picker_service.dart';
import 'package:dzeroth/features/media/data/media_repository.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processed_image.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:mocktail/mocktail.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart';

/// A real 1x1 PNG so previews decode in widget tests.
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A tiny valid-looking upload set (the bytes are never decoded in tests
/// that use [FakeImageProcessor]).
ProcessedImage fakeProcessed([String tag = 'a']) => ProcessedImage(
  fullBytes: Uint8List.fromList(List.filled(40, tag.codeUnitAt(0))),
  thumbBytes: _tinyPng,
  width: 800,
  height: 600,
  fullMd5: 'full-$tag',
  thumbMd5: 'thumb-$tag',
  blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
);

pb.UploadTarget uploadTarget(String mediaId, {DateTime? expiresAt}) {
  final expires = expiresAt == null
      ? null
      : Timestamp.fromDateTime(expiresAt.toUtc());
  pb.SignedUpload signed(String path) => pb.SignedUpload(
    url: 'https://storage.example/upload/$mediaId$path',
    method: 'PUT',
    headers: {
      'Content-Type': 'image/jpeg',
      'Content-MD5': 'md5-$mediaId$path',
      'x-goog-content-length-range': '0,2097152',
    }.entries,
    expiresAt: expires,
  );
  return pb.UploadTarget(
    mediaId: mediaId,
    full: signed(''),
    thumb: signed('_t'),
  );
}

pb.MediaResult readyResult(String mediaId) => pb.MediaResult(
  mediaId: mediaId,
  status: pb.MediaStatus.MEDIA_STATUS_READY,
  media: common.MediaRef(
    url: 'https://cdn.example/m/$mediaId.jpg',
    thumbUrl: 'https://cdn.example/m/${mediaId}_t.jpg',
  ),
);

pb.MediaResult rejectedResult(String mediaId, [String reason = '']) =>
    pb.MediaResult(
      mediaId: mediaId,
      status: pb.MediaStatus.MEDIA_STATUS_REJECTED,
      rejectionReason: reason,
    );

/// Picker that returns scripted bytes without a platform channel.
class FakeImagePicker implements ImagePickerService {
  List<Uint8List> next = [];
  Uint8List? nextAvatar;
  int calls = 0;
  int? lastLimit;

  /// When set, the next pick throws it (permission denied, picker crash).
  Object? failWith;

  @override
  Future<List<Uint8List>> pickImages({required int limit}) async {
    calls++;
    final failure = failWith;
    if (failure != null) {
      failWith = null;
      throw failure;
    }
    lastLimit = limit;
    final out = next.take(limit).toList();
    next = [];
    return out;
  }

  @override
  Future<Uint8List?> pickAvatar() async {
    calls++;
    final failure = failWith;
    if (failure != null) {
      failWith = null;
      throw failure;
    }
    return nextAvatar;
  }
}

/// Processor that "processes" instantly. Bytes starting with `bad` fail the
/// way a non-image would; the byte after the prefix becomes the md5 tag.
class FakeImageProcessor implements ImageProcessor {
  final List<ImagePurpose> purposes = [];

  @override
  Future<ProcessedImage> process(Uint8List bytes, ImagePurpose purpose) async {
    purposes.add(purpose);
    if (bytes.isNotEmpty && bytes.first == 0) {
      throw const UnsupportedImageException();
    }
    return fakeProcessed(String.fromCharCode(bytes.first));
  }
}

Uint8List imageBytes(String tag) => Uint8List.fromList([tag.codeUnitAt(0)]);
final Uint8List badBytes = Uint8List.fromList([0]);

class MockMediaRepository extends Mock implements MediaRepository {}

/// Registers the fallback values mocktail needs for [MockMediaRepository].
void registerMediaFallbacks() {
  registerFallbackValue(pb.MediaPurpose.MEDIA_PURPOSE_POST);
  registerFallbackValue(<ProcessedImage>[]);
  registerFallbackValue(<FinalizeRequestItem>[]);
  registerFallbackValue(pb.SignedUpload());
  registerFallbackValue(Uint8List(0));
}

/// Scripts [repo] so every image uploads and publishes: media ids are
/// `m<n>` in reservation order; [onPut] observes each PUT (to fail one).
void stubHappyUpload(
  MockMediaRepository repo, {
  Future<void> Function(pb.SignedUpload target)? onPut,
  pb.MediaResult Function(String mediaId)? result,
}) {
  var next = 0;
  when(
    () => repo.createUpload(
      idempotencyKey: any(named: 'idempotencyKey'),
      purpose: any(named: 'purpose'),
      images: any(named: 'images'),
    ),
  ).thenAnswer((invocation) async {
    final images = invocation.namedArguments[#images] as List<ProcessedImage>;
    return [
      for (final _ in images)
        uploadTarget(
          'm${++next}',
          expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        ),
    ];
  });
  when(() => repo.putObject(any(), any())).thenAnswer((invocation) async {
    await onPut?.call(invocation.positionalArguments.first as pb.SignedUpload);
  });
  when(
    () => repo.finalizeUpload(
      idempotencyKey: any(named: 'idempotencyKey'),
      items: any(named: 'items'),
    ),
  ).thenAnswer((invocation) async {
    final items =
        invocation.namedArguments[#items] as List<FinalizeRequestItem>;
    return [for (final i in items) (result ?? readyResult)(i.mediaId)];
  });
}
