import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/connect_error_mapper.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:dzeroth/features/messages/presentation/messaging_update_copy.dart';
import 'package:dzeroth/features/messages/presentation/widgets/messaging_update_required.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/messaging_fixtures.dart';

AppException _mapped(Map<String, String> metadata) => mapConnectError(
  withDetail(
    connect.Code.failedPrecondition,
    common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
    metadata: metadata,
  ),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('the copy', () {
    test('is exactly the plan text', () {
      expect(kUpdateToMessageTitle, 'Update the app to keep messaging');
      expect(
        kUpdateToMessageBody,
        "This version can't open encrypted messages.",
      );
      expect(kUpdateAction, 'Update');
      expect(kReloadToMessageTitle, 'A new version is available');
      expect(kReloadAction, 'Reload');
      expect(kIosNotYetTitle, "Messages aren't available on iPhone yet");
    });

    test('the platform word picks the look', () {
      expect(messagingUpdateKindFor('android'), MessagingUpdateKind.android);
      expect(messagingUpdateKindFor('web'), MessagingUpdateKind.web);
      expect(messagingUpdateKindFor('ios'), MessagingUpdateKind.ios);
      expect(messagingUpdateKindFor('other'), MessagingUpdateKind.android);
    });
  });

  group('MessagingUpdateRequired, one branch per platform', () {
    testWidgets('Android: update copy and an Update button that is wired', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        MessagingUpdateRequired(
          kind: MessagingUpdateKind.android,
          onUpdate: () => taps++,
        ),
      );
      expect(find.text(kUpdateToMessageTitle), findsOneWidget);
      expect(find.text(kUpdateToMessageBody), findsOneWidget);
      await tester.tap(find.text(kUpdateAction));
      expect(taps, 1);
    });

    testWidgets('Android without a store link has no button', (tester) async {
      await _pump(
        tester,
        const MessagingUpdateRequired(kind: MessagingUpdateKind.android),
      );
      expect(find.text(kUpdateToMessageTitle), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('web: new version copy and a Reload button', (tester) async {
      var reloads = 0;
      await _pump(
        tester,
        MessagingUpdateRequired(
          kind: MessagingUpdateKind.web,
          onReload: () => reloads++,
        ),
      );
      expect(find.text(kReloadToMessageTitle), findsOneWidget);
      expect(find.text(kUpdateToMessageTitle), findsNothing);
      await tester.tap(find.text(kReloadAction));
      expect(reloads, 1);
    });

    testWidgets('iOS: not available on iPhone yet, no action', (tester) async {
      await _pump(
        tester,
        MessagingUpdateRequired(
          kind: MessagingUpdateKind.ios,
          onUpdate: () {},
          onReload: () {},
        ),
      );
      expect(find.text(kIosNotYetTitle), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.text(kUpdateAction), findsNothing);
      expect(find.text(kReloadAction), findsNothing);
    });

    for (final width in [390.0, 700.0, 1300.0]) {
      testWidgets('renders at ${width.toInt()} dp without overflow', (
        tester,
      ) async {
        await _pump(
          tester,
          MessagingUpdateRequired(
            kind: MessagingUpdateKind.android,
            onUpdate: () {},
          ),
          width: width,
        );
        expect(tester.takeException(), isNull);
        expect(find.text(kUpdateToMessageTitle), findsOneWidget);
        expect(find.text(kUpdateAction), findsOneWidget);
      });
    }

    testWidgets('with no kind it follows the running platform', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await _pump(tester, const MessagingUpdateRequired());
      expect(find.text(kIosNotYetTitle), findsOneWidget);
    });
  });

  group('FEATURE_DISABLED with update_required (mid-session)', () {
    test('the mapper carries the flag, and only for "true"', () {
      final on = _mapped({'feature': 'messaging', 'update_required': 'true'});
      expect(on, isA<FeatureDisabledException>());
      final e = on as FeatureDisabledException;
      expect(e.feature, 'messaging');
      expect(e.updateRequired, isTrue);

      final plain =
          _mapped({'feature': 'messaging'}) as FeatureDisabledException;
      expect(plain.updateRequired, isFalse);
      final other = _mapped({
        'feature': 'messaging',
        'update_required': 'yes',
      }) as FeatureDisabledException;
      expect(other.updateRequired, isFalse);
    });

    test('shows the update copy, not "not available"', () {
      final e = _mapped({'feature': 'messaging', 'update_required': 'true'});
      expect(messagingErrorMessage(e), kUpdateToMessageTitle);
      expect(conversationsNoticeMessage(e), kUpdateToMessageTitle);
      expect(
        messagingErrorMessage(_mapped({'feature': 'messaging'})),
        "Messages aren't available right now.",
      );
    });
  });
}
