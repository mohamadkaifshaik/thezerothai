import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

const _url = 'https://dzeroth.com/post/1234567890123456789';

class _Share implements NativeShare {
  _Share(this.status, {this.error});

  final NativeShareStatus status;
  final Object? error;

  @override
  bool get isAvailable => true;

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async {
    if (error != null) throw error!;
    return status;
  }
}

class _Host extends StatelessWidget {
  const _Host(this.share, this.onShared, {this.onSend});

  final NativeShare share;
  final ValueChanged<PostShareChoice>? onShared;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => showPostShareMenu(
          context,
          url: _url,
          nativeShare: share,
          anchor: targetRectOf(context),
          onShared: onShared,
          onSendInMessage: onSend,
        ),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  Object? clipboardError;

  setUp(() {
    clipboardError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData' && clipboardError != null) {
            throw clipboardError!;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<List<PostShareChoice>> run(
    WidgetTester tester,
    NativeShare share,
    String row, {
    double width = 390,
    VoidCallback? onSend,
  }) async {
    final shared = <PostShareChoice>[];
    await pumpThemed(
      tester,
      _Host(share, shared.add, onSend: onSend),
      size: Size(width, 800),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(row));
    await tester.pumpAndSettle();
    return shared;
  }

  for (final width in [390.0, 1024.0, 1440.0]) {
    group('at ${width.toInt()}dp', () {
      testWidgets('Copy link, once the clipboard took it, reports copyLink', (
        tester,
      ) async {
        final shared = await run(
          tester,
          _Share(NativeShareStatus.completed),
          'Copy link',
          width: width,
        );
        expect(shared, [PostShareChoice.copyLink]);
        expect(find.text('Copied to clipboard'), findsOneWidget);
      });

      testWidgets('a refused clipboard reports nothing', (tester) async {
        clipboardError = PlatformException(code: 'denied');
        final shared = await run(
          tester,
          _Share(NativeShareStatus.completed),
          'Copy link',
          width: width,
        );
        expect(shared, isEmpty);
        expect(find.text("Couldn't copy the link. Try again."), findsOneWidget);
      });

      testWidgets('a completed share sheet reports shareVia', (tester) async {
        final shared = await run(
          tester,
          _Share(NativeShareStatus.completed),
          'Share via...',
          width: width,
        );
        expect(shared, [PostShareChoice.shareVia]);
      });

      for (final status in [
        NativeShareStatus.dismissed,
        NativeShareStatus.unavailable,
      ]) {
        testWidgets('a ${status.name} share sheet reports nothing', (
          tester,
        ) async {
          final shared = await run(
            tester,
            _Share(status),
            'Share via...',
            width: width,
          );
          expect(shared, isEmpty);
        });
      }

      testWidgets('a failing share sheet reports nothing and says so', (
        tester,
      ) async {
        final shared = await run(
          tester,
          _Share(NativeShareStatus.completed, error: StateError('x')),
          'Share via...',
          width: width,
        );
        expect(shared, isEmpty);
        expect(
          find.text("Couldn't open the share sheet. Try again."),
          findsOneWidget,
        );
      });

      testWidgets('Send in a message is not an outside share', (tester) async {
        var sent = 0;
        final shared = await run(
          tester,
          _Share(NativeShareStatus.completed),
          kSendInMessageLabel,
          width: width,
          onSend: () => sent++,
        );
        expect(sent, 1);
        expect(shared, isEmpty);
      });
    });
  }
}
