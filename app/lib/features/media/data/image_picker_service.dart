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

/// `image_picker` implementation. The picker downsizes natively (which keeps
/// the Dart decode cheap) and, on iOS, hands back JPEG for HEIC photos. It
/// is not asked to re-encode (`imageQuality`), so JPEG is compressed once,
/// by the processor, which also does the EXIF strip. HEIC from other
/// sources (Android, web) is not decodable by the pure-Dart processor and
/// shows as "Can't use this".
class PlatformImagePickerService implements ImagePickerService {
  PlatformImagePickerService({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const _maxEdge = 2048.0;

  @override
  Future<List<Uint8List>> pickImages({required int limit}) async {
    if (limit <= 0) return const [];
    final List<XFile> files;
    if (limit == 1) {
      final single = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: _maxEdge,
        maxHeight: _maxEdge,
      );
      files = single == null ? const [] : [single];
    } else {
      files = await _picker.pickMultiImage(
        maxWidth: _maxEdge,
        maxHeight: _maxEdge,
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
    );
    return file?.readAsBytes();
  }
}
