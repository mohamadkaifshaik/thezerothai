import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/shared/widgets/app_menu_item_row.dart';
import 'package:dzeroth/shared/widgets/post_share_menu.dart';
import 'package:dzeroth/shared/widgets/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/theme_harness.dart';

const _url = 'https://dzeroth.com/post/1234567890123456789';

class _FakeNativeShare implements NativeShare {
  _FakeNativeShare({this.isAvailable = true, this.error});

  @override
  bool isAvailable;
  final Object? error;
  final calls = <({String url, Rect? anchor})>[];

  @override
  Future<void> shareUrl(String url, {Rect? anchor}) async {
    calls.add((url: url, anchor: anchor));
    if (error != null) throw error!;
  }
}

/// A button that opens the menu for [_url], like the Share button does.
class _Host extends StatelessWidget {
  const _Host(this.share);

  final NativeShare share;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => showPostShareMenu(
          context,
          url: _url,
          nativeShare: share,
          anchor: trailingTargetRect(context),
        ),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  late List<String> clipboard;
  Object? clipboardError;

  setUp(() {
    clipboard = [];
    clipboardError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (clipboardError != null) throw clipboardError!;
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<void> open(
    WidgetTester tester,
    NativeShare share, {
    double width = 400,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    await pumpThemed(
      tester,
      _Host(share),
      size: Size(width, 800),
      brightness: brightness,
      textScale: textScale,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('under 600dp: a bottom sheet', () {
    testWidgets('titled, with Copy link and Share via...', (tester) async {
      final handle = tester.ensureSemantics();
      await open(tester, _FakeNativeShare(), width: 599);

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(PopupMenuItem<PostShareChoice>), findsNothing);
      expect(find.text('Share post'), findsOneWidget);
      expect(find.byType(SheetOptionRow), findsNWidgets(2));
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Share via...'), findsOneWidget);
      // No DM and no Bookmark row (W7 / W2-6 own those).
      expect(find.textContaining('Message'), findsNothing);
      expect(find.text('Bookmark'), findsNothing);
      expect(
        tester.getSize(find.byType(SheetOptionRow).first).height,
        greaterThanOrEqualTo(48),
      );
      expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
      expect(find.bySemanticsLabel('Share via...'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Copy link writes the exact URL and says so', (tester) async {
      final share = _FakeNativeShare();
      await open(tester, share);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(clipboard, [_url]);
      expect(find.text('Copied to clipboard'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(share.calls, isEmpty);
    });

    testWidgets('a refused clipboard never says Copied', (tester) async {
      clipboardError = PlatformException(code: 'denied');
      await open(tester, _FakeNativeShare());
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(clipboard, isEmpty);
      expect(find.text('Copied to clipboard'), findsNothing);
      expect(find.text("Couldn't copy the link. Try again."), findsOneWidget);
    });

    testWidgets('Share via... hands only the URL to the native sheet', (
      tester,
    ) async {
      final share = _FakeNativeShare();
      await open(tester, share);
      await tester.tap(find.text('Share via...'));
      await tester.pumpAndSettle();

      expect(share.calls, hasLength(1));
      expect(share.calls.single.url, _url);
      expect(share.calls.single.anchor, isNotNull);
      expect(clipboard, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a failing native sheet gets a toast', (tester) async {
      await open(tester, _FakeNativeShare(error: StateError('no sheet')));
      await tester.tap(find.text('Share via...'));
      await tester.pumpAndSettle();

      expect(
        find.text("Couldn't open the share sheet. Try again."),
        findsOneWidget,
      );
    });

    testWidgets('Share via... is hidden without a native share sheet', (
      tester,
    ) async {
      await open(tester, _FakeNativeShare(isAvailable: false));
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Share via...'), findsNothing);
      expect(find.byType(SheetOptionRow), findsOneWidget);
    });

    testWidgets('dismissing does nothing', (tester) async {
      final share = _FakeNativeShare();
      await open(tester, share);
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(clipboard, isEmpty);
      expect(share.calls, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  for (final width in [600.0, 1200.0]) {
    group('at ${width.toInt()}dp: a menu anchored at the button', () {
      testWidgets('Copy link and Share via... as menu rows', (tester) async {
        await open(tester, _FakeNativeShare(), width: width);

        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(PopupMenuItem<PostShareChoice>), findsNWidgets(2));
        expect(find.byType(AppMenuItemRow), findsNWidgets(2));
        expect(find.text('Copy link'), findsOneWidget);
        expect(find.text('Share via...'), findsOneWidget);
        // Opens next to the button (top right of the host), not centred.
        final menu = tester.getRect(
          find.byType(PopupMenuItem<PostShareChoice>).first,
        );
        expect(menu.right, greaterThan(width * 0.6));
        expect(menu.top, lessThan(200));
        for (final item in tester.widgetList<PopupMenuItem<PostShareChoice>>(
          find.byType(PopupMenuItem<PostShareChoice>),
        )) {
          expect(item.height, greaterThanOrEqualTo(48));
        }
      });

      testWidgets('Copy link writes the exact URL and says so', (tester) async {
        await open(tester, _FakeNativeShare(), width: width);
        await tester.tap(find.text('Copy link'));
        await tester.pumpAndSettle();

        expect(clipboard, [_url]);
        expect(find.text('Copied to clipboard'), findsOneWidget);
      });

      testWidgets('Share via... calls the native share with an anchor', (
        tester,
      ) async {
        final share = _FakeNativeShare();
        await open(tester, share, width: width);
        await tester.tap(find.text('Share via...'));
        await tester.pumpAndSettle();

        expect(share.calls.single.url, _url);
        expect(share.calls.single.anchor!.width, closeTo(48, 0.5));
      });

      testWidgets('Share via... hidden when unsupported', (tester) async {
        await open(tester, _FakeNativeShare(isAvailable: false), width: width);
        expect(find.text('Share via...'), findsNothing);
        expect(find.byType(PopupMenuItem<PostShareChoice>), findsOneWidget);
      });
    });
  }

  forEachThemeAndWidth(
    'sheet fits and has 48dp rows',
    (tester, env) async {
      await open(
        tester,
        _FakeNativeShare(),
        width: env.size.width,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Share post'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Share via...'), findsOneWidget);
      for (final row in find.byType(SheetOptionRow).evaluate()) {
        final size = (row.renderObject! as RenderBox).size;
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, env.size.width);
      }
    },
    widths: const [320],
    textScales: const [1.0, 1.3, 2.0],
  );

  forEachThemeAndWidth(
    'menu fits',
    (tester, env) async {
      await open(
        tester,
        _FakeNativeShare(),
        width: env.size.width,
        brightness: env.brightness,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Share via...'), findsOneWidget);
    },
    widths: const [600, 1200],
    textScales: const [1.0, 2.0],
  );
}
