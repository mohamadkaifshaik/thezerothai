import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Opens the system photo picker and returns the chosen files' bytes. An
/// interface so cubit and widget tests never touch a platform channel.
abstract interface class ImagePickerService {
  /// Up to [limit] photos from the gallery (empty when cancelled).
  Future<List<Uint8List>> pickImages({required int limit});

  /// One photo for the avatar (null when cancelled).
  Future<Uint8List?> pickAvatar();
}

/// `image_picker` implementation. The picker itself downsizes (and on iOS
/// transcodes HEIC) natively, which keeps the Dart decode cheap; the
/// processor still does the authoritative resize/compress and EXIF strip.
class PlatformImagePickerService implements ImagePickerService {
  PlatformImagePickerService({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const _maxEdge = 2048.0;
  static const _quality = 90;

  @override
  Future<List<Uint8List>> pickImages({required int limit}) async {
    if (limit <= 0) return const [];
    final List<XFile> files;
    if (limit == 1) {
      final single = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: _maxEdge,
        maxHeight: _maxEdge,
        imageQuality: _quality,
      );
      files = single == null ? const [] : [single];
    } else {
      files = await _picker.pickMultiImage(
        maxWidth: _maxEdge,
        maxHeight: _maxEdge,
        imageQuality: _quality,
        limit: limit,
      );
    }
    return [for (final file in files.take(limit)) await file.readAsBytes()];
  }

  @override
  Future<Uint8List?> pickAvatar() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: _maxEdge,
      maxHeight: _maxEdge,
      imageQuality: _quality,
    );
    return file?.readAsBytes();
  }
}
