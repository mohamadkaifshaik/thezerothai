import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';
import '../../../support/theme_harness.dart';

/// W7-21: the cells of the 360 / 600 / 1200 x light / dark x 1.0 / 1.3 / 2.0
/// matrix that the per-screen tests leave out: the Message requests folder,
/// the two empty states and the draft thread (new conversation), all on the
/// real router and stack.
void main() {
  final sam = common.AuthorSnapshot(
    userId: 'u-sam',
    handle: 'sam',
    displayName: 'Sam Rivera',
  );

  forEachThemeAndWidth('the Message requests folder fits', (tester, env) async {
    final server = MessagingFlowRig.serverWithRequest();
    final second = conv(
      hexId(0xc2),
      folder: Folder.FOLDER_REQUESTS,
      state: ConversationState.CONVERSATION_STATE_REQUEST,
      snippet: 'A long first message from a stranger ' * 6,
      minutesAgo: 90,
    );
    server.conversations[second.id] = second;
    final rig = MessagingFlowRig(server: server);

    await rig.pump(
      tester,
      location: AppRouter.messageRequestsPath,
      size: env.size,
      brightness: env.brightness,
      textScale: env.textScale,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Message requests'), findsOneWidget);
    expect(find.byType(ConversationRow), findsNWidgets(2));
    expect(
      tester.getSize(find.byType(ConversationRow).first).width,
      lessThanOrEqualTo(600),
    );
    await tester.pumpWidget(const SizedBox());
  }, textScales: kMatrixTextScalesLarge);

  forEachThemeAndWidth('the empty Inbox fits', (tester, env) async {
    final rig = MessagingFlowRig(server: FakeMessagingServer());

    await rig.pump(
      tester,
      size: env.size,
      brightness: env.brightness,
      textScale: env.textScale,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Welcome to your inbox'), findsOneWidget);
    expect(find.byType(ConversationRow), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, textScales: kMatrixTextScalesLarge);

  forEachThemeAndWidth('the empty Message requests folder fits', (
    tester,
    env,
  ) async {
    final rig = MessagingFlowRig(server: FakeMessagingServer());

    await rig.pump(
      tester,
      location: AppRouter.messageRequestsPath,
      size: env.size,
      brightness: env.brightness,
      textScale: env.textScale,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No message requests'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, textScales: kMatrixTextScalesLarge);

  /// Opens `/messages/new/draft` for Sam on an empty server.
  Future<FakeMessagingServer> openDraft(
    WidgetTester tester,
    MatrixEnv env,
  ) async {
    final server = FakeMessagingServer();
    final rig = MessagingFlowRig(server: server);
    await rig.pump(
      tester,
      size: env.size,
      brightness: env.brightness,
      textScale: env.textScale,
    );
    unawaited(
      rig.appRouter.router.push<void>(AppRouter.messageDraftPath, extra: sam),
    );
    await tester.pumpAndSettle();
    return server;
  }

  /// The draft with its composer: header, the empty state, the field.
  Future<void> expectDraftFits(WidgetTester tester, MatrixEnv env) async {
    await openDraft(tester, env);
    expect(tester.takeException(), isNull);
    expect(find.text('New message to Sam Rivera'), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsOneWidget);
    final field = tester.getRect(find.byKey(MessageComposer.fieldKey));
    expect(field.left, greaterThanOrEqualTo(0));
    expect(field.right, lessThanOrEqualTo(env.size.width));
    await tester.pumpWidget(const SizedBox());
  }

  /// The first send is refused (CANNOT_MESSAGE): the composer gives way to
  /// the read-only line, and everything stays inside the screen.
  Future<void> expectReadOnlyDraftFits(
    WidgetTester tester,
    MatrixEnv env,
  ) async {
    final server = await openDraft(tester, env);
    server.failures['/${MessagingService.name}/SendMessage'] = withDetail(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_CANNOT_MESSAGE,
    );
    await tester.enterText(find.byKey(MessageComposer.fieldKey), 'hi');
    await tester.pump();
    await tester.tap(find.byKey(MessageComposer.sendKey));
    await tester.pumpAndSettle();

    expect(find.text(kThreadReadOnlyText), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsNothing);
    final line = tester.getRect(find.text(kThreadReadOnlyText));
    expect(line.left, greaterThanOrEqualTo(0));
    expect(line.right, lessThanOrEqualTo(env.size.width));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }

  forEachThemeAndWidth(
    'the draft thread fits',
    expectDraftFits,
    textScales: kMatrixTextScalesLarge,
  );

  // DEFECT (reported, not fixed: this ticket is test-only). The draft's
  // empty state is an `AppEmptyView` (a non-scrolling Column) inside an
  // `Expanded`; when the space left by the header and the composer / the
  // read-only line is shorter than its content it overflows: 360 x 640 at
  // text scale 2.0 (the first state) and 360 x 800 at 2.0 after the first
  // send is refused with CANNOT_MESSAGE (39 px). Source:
  // app/lib/features/messages/presentation/draft_thread_screen.dart (the
  // `AppEmptyView` in `_DraftView`). The two tests below describe the
  // wanted behavior and are skipped (`skip: true`; the name says why) until
  // it is fixed.
  for (final brightness in Brightness.values) {
    testWidgets(
      'defect: DraftThreadScreen empty state overflows on a short phone '
      '[${brightness.name} 360x640 x2.0]',
      (tester) => expectDraftFits(
        tester,
        MatrixEnv(
          brightness: brightness,
          size: const Size(360, 640),
          textScale: 2.0,
        ),
      ),
      skip: true,
    );
    testWidgets(
      'defect: DraftThreadScreen empty state overflows by 39 px after '
      'CANNOT_MESSAGE [${brightness.name} 360dp x2.0]',
      (tester) => expectReadOnlyDraftFits(
        tester,
        MatrixEnv(
          brightness: brightness,
          size: const Size(360, 800),
          textScale: 2.0,
        ),
      ),
      skip: true,
    );
  }

  forEachThemeAndWidth(
    'the draft thread is read-only after CANNOT_MESSAGE',
    expectReadOnlyDraftFits,
    widths: const [600, 1200],
    textScales: kMatrixTextScalesLarge,
  );
  forEachThemeAndWidth(
    'the draft thread is read-only after CANNOT_MESSAGE (phone)',
    expectReadOnlyDraftFits,
    widths: const [360],
    textScales: const [1.0, 1.3],
  );
}
