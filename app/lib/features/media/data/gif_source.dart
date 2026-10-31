import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Where a post's GIF comes from (ADR-0029 F9). Today only the device; the
/// provider picker of W6-24 is another implementation that hands back the
/// same thing (the GIF's bytes), so the composer never changes. An interface
/// so cubit and widget tests never touch a platform channel.
abstract interface class GifSource {
  /// One GIF's bytes, or null when the user cancelled. Throws when the
  /// picker or its permission fails.
  Future<Uint8List?> pick();
}

/// Picks from the device gallery through `image_picker`.
///
/// The picker is asked for the file **as is**: any `maxWidth`, `maxHeight` or
/// `imageQuality` makes Android and iOS re-encode the picture and the
/// animation is lost. It cannot filter to `.gif` (a non-GIF choice is
/// refused afterwards by `GifPreparer`, with "That file isn't a GIF."), and
/// on the web the file input is the picker's own `image/*` one.
class DeviceGifSource implements GifSource {
  DeviceGifSource({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<Uint8List?> pick() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    return file?.readAsBytes();
  }
}
