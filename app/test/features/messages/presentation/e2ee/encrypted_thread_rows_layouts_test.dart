import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encrypted_thread_items.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/own_device_alert.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/system_line_row.dart';
import 'package:dzeroth/features/messages/presentation/thread_items.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/theme_harness.dart';

// The rows of an encrypted thread at phone, tablet and desktop widths and at
// text scale 2.0: the same rows, only their width changes.

const _long =
    'A long message that has to wrap onto several lines at every width and '
    'at the largest text scale without any overflow at all.';

DecryptedMessage _m(
  String id, {
  bool mine = false,
  EncryptedMessageState state = EncryptedMessageState.visible,
  MessageCheck check = MessageCheck.ok,
  SendProgress progress = SendProgress.delivered,
  SendProblem problem = SendProblem.none,
  String text = _long,
  String sharedPostId = '',
}) => DecryptedMessage(
  id: id,
  at: DateTime.now().toUtc(),
  mine: mine,
  state: state,
  check: check,
  progress: progress,
  problem: problem,
  text: state == EncryptedMessageState.visible && check == MessageCheck.ok
      ? text
      : '',
  sharedPostId: sharedPostId,
);

SystemLineEntry _l(SystemLineKind kind, [LineSide? side]) => SystemLineEntry(
  id: 'l-$kind-$side',
  at: DateTime.now().toUtc(),
  kind: kind,
  side: side,
);

Widget _thread() {
  final entries = <ThreadEntry>[
    _m(
      'a',
      mine: true,
      progress: SendProgress.notSent,
      problem: SendProblem.retryable,
    ),
    _m('b', mine: true, progress: SendProgress.sending),
    _m('c', mine: true, progress: SendProgress.waiting),
    _m(
      'd',
      mine: true,
      progress: SendProgress.notSent,
      problem: SendProblem.tryTomorrow,
    ),
    _m(
      'e',
      mine: true,
      progress: SendProgress.notSent,
      problem: SendProblem.peerHasNoDevice,
    ),
    _m(
      'f',
      mine: true,
      progress: SendProgress.notSent,
      problem: SendProblem.blocked,
    ),
    _m('g', mine: false, state: EncryptedMessageState.undecryptable),
    _m('h', mine: false, check: MessageCheck.unverified),
    _m('i', mine: false, check: MessageCheck.undecodable),
    _m('j', mine: false, state: EncryptedMessageState.removed),
    _m('k', mine: true, state: EncryptedMessageState.deletedAccount),
    _m('p', mine: true, sharedPostId: 'post-1'),
    _m('q', mine: false, sharedPostId: 'post-1'),
    _l(SystemLineKind.encryptionReset),
    _l(SystemLineKind.deviceAdded, LineSide.theirs),
    _l(SystemLineKind.deviceRemoved, LineSide.theirs),
    _l(SystemLineKind.deviceRemoved, LineSide.mine),
    _l(SystemLineKind.deviceRemoved, LineSide.unattributed),
    _l(SystemLineKind.unknownDevice),
    _l(SystemLineKind.deviceAdded, LineSide.mine),
    _m('z', mine: false),
  ];
  final items = buildEncryptedThreadItems(entries);
  return SingleChildScrollView(
    child: Column(
      children: [
        for (final item in items)
          switch (item) {
            EncryptedMessageItem() => MessageBubble.encrypted(
              entry: item.message,
              peerName: 'Sam Rivera',
              now: DateTime.now().toUtc(),
              firstOfGroup: item.firstOfGroup,
              lastOfGroup: item.lastOfGroup,
              onOpenLink: (_) {},
              onOpenPost: (_) {},
              onRetry: (_) {},
            ),
            SystemLineItem() => SystemLineRow(
              line: item.line,
              peerName: 'Sam Rivera',
            ),
            OwnDeviceAlertItem() => OwnDeviceAlert(onCheckDevices: () {}),
            DaySeparatorItem() => const SizedBox.shrink(),
            MessageItem() => const SizedBox.shrink(),
          },
      ],
    ),
  );
}

void main() {
  forEachThemeAndWidth(
    'every row state fits without overflow',
    (tester, env) async {
      await pumpThemed(
        tester,
        _thread(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  for (final width in kRedesignWidths) {
    testWidgets('bubbles keep the width fraction at $width', (tester) async {
      await pumpThemed(
        tester,
        MessageBubble.encrypted(
          entry: _m('w', mine: true),
          peerName: 'Sam',
          now: DateTime.now().toUtc(),
          firstOfGroup: true,
          lastOfGroup: true,
          onOpenLink: (_) {},
        ),
        size: Size(width, 800),
      );
      final box = tester.getSize(find.byKey(const ValueKey('bubble-w')));
      expect(
        box.width,
        lessThanOrEqualTo(
          (width - 2 * AppSpacing.md) * kBubbleMaxWidthFraction + 0.5,
        ),
      );
    });

    testWidgets('a system line is at most the bubble column at $width', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        SystemLineRow(
          line: _l(SystemLineKind.deviceRemoved, LineSide.mine),
          peerName: 'Sam',
        ),
        size: Size(width, 800),
        textScale: 2.0,
      );
      final text = tester.getSize(find.byType(Text).first);
      final column = width - 2 * AppSpacing.md;
      expect(
        text.width,
        lessThanOrEqualTo(
          width >= AppBreakpoints.mobile
              ? column * kBubbleMaxWidthFraction
              : column,
        ),
      );
    });

    testWidgets('the alert is capped at 480 only on desktop at $width', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        OwnDeviceAlert(onCheckDevices: () {}),
        size: Size(width, 800),
      );
      final size = tester.getSize(find.byType(DecoratedBox).first);
      if (width >= AppBreakpoints.tablet) {
        expect(size.width, AppMessagesLayout.ownDeviceAlertMaxWidth);
        expect(tester.getCenter(find.byType(DecoratedBox).first).dx, width / 2);
      } else {
        expect(size.width, width - 2 * AppSpacing.md);
      }
    });
  }
}
