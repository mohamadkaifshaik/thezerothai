import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/own_device_alert.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/system_line_row.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/theme_harness.dart';

SystemLineEntry _line(SystemLineKind kind, [LineSide? side]) => SystemLineEntry(
  id: 'l1',
  at: DateTime.now().toUtc(),
  kind: kind,
  side: side,
);

Widget _row(SystemLineEntry line, {String peer = 'Sam Rivera'}) =>
    SystemLineRow(line: line, peerName: peer);

void main() {
  final cases = <(String, SystemLineEntry, String)>[
    ('reset', _line(SystemLineKind.encryptionReset), kLineEncryptionReset),
    (
      'added, theirs',
      _line(SystemLineKind.deviceAdded, LineSide.theirs),
      lineDeviceAddedTheirs('Sam Rivera'),
    ),
    (
      'removed, theirs',
      _line(SystemLineKind.deviceRemoved, LineSide.theirs),
      lineDeviceRemovedTheirs('Sam Rivera'),
    ),
    (
      'removed, mine',
      _line(SystemLineKind.deviceRemoved, LineSide.mine),
      kLineDeviceRemovedMine,
    ),
    (
      'removed, unattributed',
      _line(SystemLineKind.deviceRemoved, LineSide.unattributed),
      kLineUnknownDeviceRemoved,
    ),
    (
      'removed, no side',
      _line(SystemLineKind.deviceRemoved),
      kLineUnknownDeviceRemoved,
    ),
    ('unknown device', _line(SystemLineKind.unknownDevice), kLineUnknownDevice),
    (
      'added, unattributed',
      _line(SystemLineKind.deviceAdded, LineSide.unattributed),
      kLineUnknownDevice,
    ),
    ('added, no side', _line(SystemLineKind.deviceAdded), kLineUnknownDevice),
  ];

  for (final (name, line, text) in cases) {
    testWidgets('line text: $name', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _row(line));
      expect(find.text(text), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel(text));
      expect(node.getSemanticsData().flagsCollection.isButton, isFalse);
      handle.dispose();
    });
  }

  testWidgets('the reset line carries the small lock icon', (tester) async {
    await pumpThemed(tester, _row(_line(SystemLineKind.encryptionReset)));
    final icon = tester.widget<Icon>(find.byIcon(Icons.lock_outline));
    expect(icon.size, AppMessagesLayout.lineIcon);
    final text = tester.widget<Text>(find.text(kLineEncryptionReset));
    final colors = Theme.of(tester.element(find.byType(Text))).colorScheme;
    expect(text.style?.color, colors.onSurfaceVariant);
  });

  testWidgets('a quiet line has no warning icon', (tester) async {
    await pumpThemed(
      tester,
      _row(_line(SystemLineKind.deviceRemoved, LineSide.mine)),
    );
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
  });

  testWidgets('the unknown-device line uses the error colour and an icon', (
    tester,
  ) async {
    await pumpThemed(tester, _row(_line(SystemLineKind.unknownDevice)));
    final colors = Theme.of(tester.element(find.byType(Text))).colorScheme;
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
      tester.widget<Text>(find.text(kLineUnknownDevice)).style?.color,
      colors.error,
    );
  });

  testWidgets('the alert shows title, body and Check your devices, which calls '
      'back', (tester) async {
    var calls = 0;
    await pumpThemed(tester, OwnDeviceAlert(onCheckDevices: () => calls++));
    expect(find.text(kOwnDeviceAlertTitle), findsOneWidget);
    expect(find.text(kOwnDeviceAlertBody), findsOneWidget);
    expect(find.text(kOwnDeviceAlertAction), findsOneWidget);
    await tester.tap(find.byType(AppPillButton));
    expect(calls, 1);
  });

  testWidgets('the alert is a live region', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, OwnDeviceAlert(onCheckDevices: () {}));
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp(kOwnDeviceAlertTitle)),
    );
    expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    final header = tester.getSemantics(find.text(kOwnDeviceAlertTitle));
    expect(header.getSemanticsData().flagsCollection.isHeader, isTrue);
    handle.dispose();
  });
}
