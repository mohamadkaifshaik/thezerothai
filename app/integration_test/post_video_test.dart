import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dzeroth/features/media/data/video_source.dart';
import 'package:dzeroth/features/media/domain/image_processor.dart';
import 'package:dzeroth/features/media/domain/processing_cancellation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:integration_test/integration_test.dart';

// One second of synthetic blue VP9 video, 64 x 48, with no audio.
const _webm =
    'GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAJiEU2bdLpN'
    'u4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHGTbuMU6uEElTDZ1OsggEnTbuMU6uEHFO7a1Os'
    'ggJM7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmoCrX'
    'sYMPQkBNgIRMYXZmV0GETGF2ZkSJiECPQAAAAAAAFlSua9yuAQAAAAAAAFPXgQFzxYgAAAAA'
    'AAAAAZyBACK1nIN1bmSGhVZfVlA5g4EBI+ODhAdzWUDgmLCBQLqBMJqBAlWwjFW5gQFVt4EB'
    'VbiBAlXugQDsAQAAAAAAAAIAABJUw2fUc3PRY8CLY8WIAAAAAAAAAAFnyJxFo4dFTkNPREVS'
    'RIePTGF2YyBsaWJ2cHgtdnA5Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMS4wMDAwMDAwMDAA'
    'H0O2dUDG54EAo66BAACAgkmDQgAD8AL2ADgkHBhKAAAwYAAAE7//+/04ABH////6sdZ////+'
    'QYgAo5OBAH0AhgBAkpwAUAAAAyAAAFRwo5OBAPoAhgBAkpwATuAAAyAAAFRwo5OBAXcAhgBA'
    'kpwAUAAAAyAAAFRwo5OBAfQAhgBAkpwATUAAAyAAAFRwo5OBAnEAhgBAkpwAUAAAAyAAAFRw'
    'o5OBAu4AhgBAkpwATuAAAyAAAFRwo5OBA2sAhgBAkpwAUAAAAyAAAFRwHFO7a5G7j7OBALeK'
    '94EB8YIBgPCBAw==';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('prepares a WebM as an MP4 upload with a JPEG poster', (_) async {
    // The picker path has no usable WebM extension. Detect the container
    // from the bytes, just as the composer must for browser blob URLs.
    await withVideoPreview(base64Decode(_webm), (path) async {
      final clip = await preparePostVideo(
        XFile(path),
        const IsolateImageProcessor(),
        ProcessingCancellation(),
      );
      expect(clip.contentType, 'video/mp4');
      expect(ascii.decode(clip.fullBytes.sublist(4, 8)), 'ftyp');
      expect((clip.width, clip.height), (64, 48));
      expect(clip.thumbContentType, 'image/jpeg');
      expect(clip.thumbBytes.take(2), [0xff, 0xd8]);
      expect(clip.fullMd5, base64Encode(md5.convert(clip.fullBytes).bytes));
      expect(clip.thumbMd5, base64Encode(md5.convert(clip.thumbBytes).bytes));
    });
  });
}
