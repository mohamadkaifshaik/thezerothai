import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/outgoing_bubble.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/theme_harness.dart';

final DateTime _now = DateTime.now().toUtc();

DecryptedMessage _entry({
  String id = 'm1',
  bool mine = false,
  EncryptedMessageState state = EncryptedMessageState.visible,
  MessageCheck check = MessageCheck.ok,
  String text = 'hello there',
  String sharedPostId = '',
  SendProgress progress = SendProgress.delivered,
  SendProblem problem = SendProblem.none,
  AppException? error,
  bool canReport = false,
}) => DecryptedMessage(
  id: id,
  at: _now.subtract(const Duration(minutes: 5)),
  mine: mine,
  state: state,
  check: check,
  text: text,
  sharedPostId: sharedPostId,
  progress: progress,
  problem: problem,
  error: error,
  canReport: canReport,
);

Widget _bubble(
  DecryptedMessage entry, {
  bool last = true,
  bool linksEnabled = true,
  void Function(Rect)? onReport,
  void Function(String)? onOpenPost,
  void Function(String)? onRetry,
  void Function(Uri)? onOpenLink,
}) => MessageBubble.encrypted(
  entry: entry,
  peerName: 'Sam Rivera',
  now: _now,
  firstOfGroup: true,
  lastOfGroup: last,
  linksEnabled: linksEnabled,
  onOpenLink: onOpenLink ?? (_) {},
  onReport: onReport,
  onOpenPost: onOpenPost,
  onRetry: onRetry,
);

Finder _decorated(String id) => find.byKey(ValueKey('bubble-$id'));

BoxDecoration _decoration(WidgetTester tester, String id) =>
    (tester.widget<DecoratedBox>(_decorated(id)).decoration as BoxDecoration);

Alignment _side(WidgetTester tester, String id) {
  final rect = tester.getRect(_decorated(id));
  final width = tester.view.physicalSize.width;
  // The end side sits in the right half of a left-to-right view.
  return rect.center.dx > width / 2
      ? Alignment.centerRight
      : Alignment.centerLeft;
}

void main() {
  testWidgets('mine decides the side', (tester) async {
    await pumpThemed(tester, _bubble(_entry(mine: true)));
    expect(_side(tester, 'm1'), Alignment.centerRight);
    expect(_decoration(tester, 'm1').gradient, isNotNull);

    await pumpThemed(tester, _bubble(_entry(mine: false)));
    expect(_side(tester, 'm1'), Alignment.centerLeft);
  });

  testWidgets(
    'an undecryptable row is placed and decorated identically with mine true '
    'and mine false, and never as an own bubble',
    (tester) async {
      Future<(Rect, BoxDecoration)> draw(bool mine) async {
        await pumpThemed(
          tester,
          _bubble(
            _entry(
              mine: mine,
              state: EncryptedMessageState.undecryptable,
              text: '',
            ),
          ),
        );
        return (tester.getRect(_decorated('m1')), _decoration(tester, 'm1'));
      }

      final a = await draw(true);
      final b = await draw(false);
      expect(a.$1, b.$1);
      expect(a.$2.border, b.$2.border);
      expect(a.$2.borderRadius, b.$2.borderRadius);
      expect(a.$2.gradient, isNull);
      expect(a.$2.boxShadow, isNull);
      expect(a.$2.color, b.$2.color);
      expect(_side(tester, 'm1'), Alignment.centerLeft);
    },
  );

  testWidgets('each placeholder shows its fixed text in tombstone style', (
    tester,
  ) async {
    final cases = <DecryptedMessage, String>{
      _entry(check: MessageCheck.unverified, text: ''): kCouldNotVerifyText,
      _entry(check: MessageCheck.undecodable, text: ''): kCannotDisplayText,
      _entry(state: EncryptedMessageState.undecryptable, text: ''):
          kCouldNotDecryptText,
      _entry(state: EncryptedMessageState.removed, text: ''):
          kMessageRemovedText,
      _entry(state: EncryptedMessageState.deletedAccount, text: ''):
          kMessageDeletedText,
    };
    for (final c in cases.entries) {
      await pumpThemed(tester, _bubble(c.key));
      final text = tester.widget<Text>(find.text(c.value));
      expect(text.style?.fontStyle, FontStyle.italic, reason: c.value);
      final colors = Theme.of(tester.element(find.text(c.value))).colorScheme;
      expect(text.style?.color, colors.onSurfaceVariant);
      final d = _decoration(tester, 'm1');
      expect(d.color, colors.surfaceContainerHigh);
      expect(d.border, isNotNull);
    }
  });

  testWidgets('unverified and undecodable keep Report when canReport, undecryptable never '
      'does', (tester) async {
    var reports = 0;
    void report(Rect _) => reports++;
    for (final check in [MessageCheck.unverified, MessageCheck.undecodable]) {
      await pumpThemed(
        tester,
        _bubble(
          _entry(check: check, text: '', canReport: true),
          onReport: report,
        ),
      );
      await tester.longPress(_decorated('m1'));
      await tester.pump();
    }
    expect(reports, 2);

    for (final state in [
      EncryptedMessageState.undecryptable,
      EncryptedMessageState.removed,
      EncryptedMessageState.deletedAccount,
    ]) {
      await pumpThemed(
        tester,
        _bubble(
          _entry(state: state, text: '', canReport: false),
          onReport: report,
        ),
      );
      await tester.longPress(_decorated('m1'));
      await tester.pump();
    }
    expect(reports, 2);
  });

  testWidgets('own messages never have Report', (tester) async {
    var reports = 0;
    // Even a caller that wrongly passes a handler and canReport on an own row.
    await pumpThemed(
      tester,
      _bubble(_entry(mine: true, canReport: true), onReport: (_) => reports++),
    );
    await tester.longPress(_decorated('m1'));
    await tester.pump();
    expect(reports, 0);
  });

  testWidgets('a reportable peer message calls onReport on long press', (
    tester,
  ) async {
    var reports = 0;
    await pumpThemed(
      tester,
      _bubble(_entry(canReport: true), onReport: (_) => reports++),
    );
    await tester.longPress(_decorated('m1'));
    await tester.pump();
    expect(reports, 1);
  });

  testWidgets('sending and waiting show their status and are not buttons', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final retried = <String>[];
    for (final (progress, status) in [
      (SendProgress.sending, kOutgoingSendingText),
      (SendProgress.waiting, kOutgoingWaitingText),
    ]) {
      await pumpThemed(
        tester,
        _bubble(_entry(mine: true, progress: progress), onRetry: retried.add),
      );
      expect(find.text(status), findsOneWidget);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: _decorated('m1'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, AppMessagesLayout.pendingOpacity);
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('You said hello there')),
      );
      expect(node.label, contains(status));
      expect(node.getSemanticsData().flagsCollection.isButton, isFalse);
      await tester.tap(find.text(status));
      expect(retried, isEmpty);
    }
    handle.dispose();
  });

  testWidgets('Not sent. Tap to retry calls onRetry with the row id', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final retried = <String>[];
    await pumpThemed(
      tester,
      _bubble(
        _entry(
          id: 'local-7',
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.retryable,
        ),
        onRetry: retried.add,
      ),
    );
    expect(find.text(kOutgoingNotSentText), findsOneWidget);
    final colors = Theme.of(tester.element(_decorated('local-7'))).colorScheme;
    expect(
      (_decoration(tester, 'local-7').border as Border).top.color,
      colors.error,
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('You said hello there')),
    );
    expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
    await tester.tap(find.text(kOutgoingNotSentText));
    expect(retried, ['local-7']);
    handle.dispose();
  });

  testWidgets(
    'blocked, peerHasNoDevice and tryTomorrow show their text and are not '
    'tappable',
    (tester) async {
      final retried = <String>[];
      for (final (problem, text) in [
        (SendProblem.blocked, kOutgoingNotSentBlockedText),
        (SendProblem.peerHasNoDevice, kStatePeerNoDeviceText),
        (SendProblem.tryTomorrow, kOutgoingTryTomorrowText),
      ]) {
        await pumpThemed(
          tester,
          _bubble(
            _entry(
              mine: true,
              progress: SendProgress.notSent,
              problem: problem,
            ),
            onRetry: retried.add,
          ),
        );
        expect(find.text(text), findsOneWidget);
        await tester.tap(find.text(text));
        expect(retried, isEmpty, reason: '$problem');
      }
    },
  );

  testWidgets('refused shows messagingErrorMessage of the error', (
    tester,
  ) async {
    const error = RateLimitedException('x', retryAfter: Duration(seconds: 60));
    await pumpThemed(
      tester,
      _bubble(
        _entry(
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.refused,
          error: error,
        ),
        onRetry: (_) {},
      ),
    );
    expect(find.text(messagingErrorMessage(error)), findsOneWidget);
  });

  testWidgets('a refusal with no typed reason reads Not sent', (tester) async {
    await pumpThemed(
      tester,
      _bubble(
        _entry(
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.refused,
        ),
      ),
    );
    expect(find.text(kOutgoingNotSentBlockedText), findsOneWidget);
  });

  testWidgets(
    'a shared post shows the card and View post calls onOpenPost; nothing is '
    'fetched',
    (tester) async {
      String? opened;
      await pumpThemed(
        tester,
        _bubble(
          _entry(text: 'look at this', sharedPostId: 'post-9'),
          onOpenPost: (id) => opened = id,
        ),
      );
      expect(find.byKey(kSharedPostCardKey), findsOneWidget);
      expect(find.text('look at this'), findsOneWidget);
      expect(find.text(kConversationSharedPostSnippet), findsOneWidget);
      expect(find.text(kViewSharedPostLabel), findsOneWidget);
      await tester.tap(find.byType(AppPillButton));
      expect(opened, 'post-9');
      // No repository or provider is in the tree: drawing it needed none.
    },
  );

  testWidgets('a shared post without a caption shows only the card', (
    tester,
  ) async {
    await pumpThemed(
      tester,
      _bubble(
        _entry(text: '', sharedPostId: 'post-9'),
        onOpenPost: (_) {},
      ),
    );
    expect(find.byKey(kSharedPostCardKey), findsOneWidget);
    expect(find.byType(MessageText), findsNothing);
  });

  testWidgets('links are plain text when linksEnabled is false', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    Uri? opened;
    await pumpThemed(
      tester,
      _bubble(
        _entry(text: 'see https://example.com/a'),
        linksEnabled: false,
        onOpenLink: (u) => opened = u,
      ),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Sam Rivera said')),
    );
    expect(
      node.getSemanticsData().customSemanticsActionIds,
      anyOf(isNull, isEmpty),
    );
    final rich = tester.widget<Text>(find.byType(Text).first);
    final span = rich.textSpan as TextSpan;
    expect(
      span.children!.whereType<TextSpan>().where((s) => s.recognizer != null),
      isEmpty,
    );
    expect(opened, isNull);

    await pumpThemed(
      tester,
      _bubble(_entry(text: 'see https://example.com/a')),
    );
    final on = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Sam Rivera said')),
    );
    expect(on.getSemanticsData().customSemanticsActionIds, hasLength(1));
    handle.dispose();
  });

  testWidgets('spoken label of a placeholder is its text', (tester) async {
    final handle = tester.ensureSemantics();
    for (final (entry, text) in [
      (
        _entry(state: EncryptedMessageState.undecryptable, text: ''),
        kCouldNotDecryptText,
      ),
      (_entry(check: MessageCheck.unverified, text: ''), kCouldNotVerifyText),
      (
        _entry(mine: true, state: EncryptedMessageState.removed, text: ''),
        kMessageRemovedText,
      ),
    ]) {
      await pumpThemed(tester, _bubble(entry));
      expect(
        find.bySemanticsLabel(RegExp('^${RegExp.escape(text)}')),
        findsOneWidget,
        reason: text,
      );
    }
    handle.dispose();
  });

  testWidgets('spoken labels: own "You said", peer "<name> said, <time>"', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, _bubble(_entry(mine: true)));
    expect(find.bySemanticsLabel('You said hello there'), findsOneWidget);
    await pumpThemed(tester, _bubble(_entry()));
    expect(
      find.bySemanticsLabel('Sam Rivera said hello there, 5 minutes ago'),
      findsOneWidget,
    );
    handle.dispose();
  });
}
