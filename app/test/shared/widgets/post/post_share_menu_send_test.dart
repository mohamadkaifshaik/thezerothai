import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/shared/widgets/post/post_share_menu.dart';
import 'package:dzeroth/shared/widgets/primitives/app_menu_item_row.dart';
import 'package:dzeroth/shared/widgets/primitives/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

const _url = 'https://dzeroth.com/post/1234567890123456789';

class _NoShare implements NativeShare {
  @override
  bool get isAvailable => true;

  @override
  Future<NativeShareStatus> shareUrl(String url, {Rect? anchor}) async =>
      NativeShareStatus.completed;
}

class _Host extends StatelessWidget {
  const _Host({this.onSend});

  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: Builder(
      builder: (context) => TextButton(
        onPressed: () => showPostShareMenu(
          context,
          url: _url,
          nativeShare: _NoShare(),
          anchor: targetRectOf(context),
          onSendInMessage: onSend,
        ),
        child: const Text('open'),
      ),
    ),
  );
}

void main() {
  Future<void> open(
    WidgetTester tester, {
    VoidCallback? onSend,
    required double width,
  }) async {
    await pumpThemed(tester, _Host(onSend: onSend), size: Size(width, 800));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  for (final width in [390.0, 1024.0, 1440.0]) {
    final phone = width < 600;
    group('at ${width.toInt()}dp (${phone ? 'sheet' : 'anchored menu'})', () {
      testWidgets('without the callback there is no "Send in a message"', (
        tester,
      ) async {
        await open(tester, width: width);
        expect(find.text(kSendInMessageLabel), findsNothing);
        expect(find.text('Copy link'), findsOneWidget);
      });

      testWidgets('with it, the row leads and calls it once the menu '
          'is closed', (tester) async {
        var calls = 0;
        await open(tester, width: width, onSend: () => calls++);

        expect(find.text(kSendInMessageLabel), findsOneWidget);
        final rows = phone
            ? find.byType(SheetOptionRow)
            : find.byType(AppMenuItemRow);
        expect(rows, findsNWidgets(3));
        // First row: above Copy link.
        expect(
          tester.getTopLeft(find.text(kSendInMessageLabel)).dy,
          lessThan(tester.getTopLeft(find.text('Copy link')).dy),
        );

        await tester.tap(find.text(kSendInMessageLabel));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.text('Copy link'), findsNothing);
      });

      testWidgets('dismissing the menu does not call it', (tester) async {
        var calls = 0;
        await open(tester, width: width, onSend: () => calls++);
        await tester.tapAt(const Offset(5, 790));
        await tester.pumpAndSettle();
        expect(calls, 0);
      });
    });
  }
}
