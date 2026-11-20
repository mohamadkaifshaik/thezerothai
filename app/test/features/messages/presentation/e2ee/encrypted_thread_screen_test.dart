import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/conversation_encryption_note.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/own_device_alert.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/features/messages/presentation/widgets/message_composer.dart';
import 'package:dzeroth/features/messages/presentation/widgets/not_encrypted_note.dart';
import 'package:dzeroth/features/messages/presentation/widgets/request_banner.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../support/fake_encrypted_messaging.dart';
import '../../../../support/fake_encryption_device.dart';
import '../../../../support/messaging_fixtures.dart';
import '../../../../support/messaging_flow_rig.dart';
import '../../../../support/thread_test_support.dart';

const _mls = ConversationEncryption.CONVERSATION_ENCRYPTION_MLS;
const _none = ConversationEncryption.CONVERSATION_ENCRYPTION_NONE;

const _ready = ConversationSecurity(state: ConversationEncryptionState.ready);

void main() {
  final ref = ThreadRef.conversation(kThreadId);
  // Relative to the clock (the fixed-date guard), after the cached rows.
  final base = DateTime.now().toUtc().add(const Duration(hours: 1));

  DecryptedMessage entry(
    String id,
    String text, {
    bool mine = false,
    Duration after = Duration.zero,
    SendProgress progress = SendProgress.delivered,
    SendProblem problem = SendProblem.none,
  }) => DecryptedMessage(
    id: id,
    at: base.add(after),
    mine: mine,
    text: text,
    progress: progress,
    problem: problem,
  );

  /// Opens the conversation `kThreadId` with [encryption] on the header.
  Future<
    ({
      FakeEncryptedMessaging port,
      FakeEncryptionDevice device,
      MessagingFlowRig rig,
    })
  >
  open(
    WidgetTester tester, {
    ConversationEncryption encryption = _mls,
    List<ThreadEntry> entries = const [],
    ConversationSecurity security = _ready,
    bool hasMore = false,
    bool request = false,
    Set<String> extraFlags = const {kFeatureE2eeDm},
    bool withPort = true,
    void Function(dynamic server)? tweak,
    Size size = const Size(390, 844),
  }) async {
    final server = request
        ? MessagingFlowRig.serverWithRequest()
        : MessagingFlowRig.serverWithConversation();
    server.conversations[kThreadId]!.encryption = encryption;
    tweak?.call(server);
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    port.setThread(
      ref,
      EncryptedThread(
        conversationId: kThreadId,
        entries: entries,
        hasMore: hasMore,
        security: security,
      ),
    );
    final device = FakeEncryptionDevice();
    final rig = MessagingFlowRig(
      server: server,
      flags: {'messaging', 'graph', 'reports', 'ui_shell', ...extraFlags},
    );
    await rig.pump(
      tester,
      location: AppRouter.messagePath(kThreadId),
      size: size,
      encrypted: withPort ? port : null,
      device: withPort ? device : null,
    );
    return (port: port, device: device, rig: rig);
  }

  Finder bubble(String id) => find.byKey(ValueKey('bubble-$id'));

  testWidgets('an MLS thread draws the port entries as bubbles with the '
      'encrypted note above the oldest one', (tester) async {
    await open(
      tester,
      entries: [
        entry(
          'e2',
          'second secret',
          mine: true,
          after: const Duration(minutes: 1),
        ),
        entry('e1', 'first secret'),
      ],
    );
    expect(find.text('first secret'), findsOneWidget);
    expect(find.text('second secret'), findsOneWidget);
    expect(find.text(kEncryptedNoteText), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(kEncryptedNoteText)).dy,
      lessThan(tester.getTopLeft(find.text('first secret')).dy),
    );
    expect(find.text(kMessagesNotEncryptedText), findsNothing);
    // The cached plaintext rows are older than the first entry: they sit
    // above the separator, nothing else of the server's text is read.
    expect(find.text(kNotEncryptedAboveText), findsOneWidget);
  });

  testWidgets('the note is the encrypted one and How this works is a link '
      'only when there is something to open', (tester) async {
    await open(tester, entries: [entry('e1', 'hi')]);
    // Until the explanation panel exists the thread passes no handler.
    expect(find.text(kEncryptionHowItWorksLabel), findsNothing);

    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationEncryptionNote(
            encrypted: true,
            onLearnMore: () => opened++,
          ),
        ),
      ),
    );
    await tester.tap(find.text(kEncryptionHowItWorksLabel));
    expect(opened, 1);
    expect(find.text(kEncryptedNoteText), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ConversationEncryptionNote(encrypted: false)),
      ),
    );
    expect(find.byType(NotEncryptedNote), findsOneWidget);
    expect(find.text(kEncryptedNoteText), findsNothing);
  });

  testWidgets('an empty ready thread for an MLS header shows the empty state '
      'with the encrypted note', (tester) async {
    await open(tester);
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text(kEncryptedNoteText), findsOneWidget);
    expect(find.byKey(MessageComposer.fieldKey), findsOneWidget);
  });

  testWidgets('earlier plaintext messages stay visible above the separator '
      'after a conversation becomes encrypted', (tester) async {
    // The cache holds m1 (10 s before kMsgBase) and m2 (5 s before); the first
    // encrypted entry is a minute after kMsgBase, and one plaintext row is
    // newer than it.
    final firstAt = kMsgBase.toUtc().add(const Duration(minutes: 1));
    await open(
      tester,
      entries: [
        DecryptedMessage(id: 'e1', at: firstAt, mine: false, text: 'secret'),
      ],
      tweak: (server) {
        server.messages[kThreadId]!.insert(
          0,
          msg(
            3,
            conversationId: kThreadId,
            secondsAgo: -120,
            text: 'newer plain',
          ),
        );
      },
    );
    expect(find.text('m2'), findsOneWidget);
    expect(find.text('m1'), findsOneWidget);
    expect(find.text(kNotEncryptedAboveText), findsOneWidget);
    expect(find.text('newer plain'), findsNothing);
    final separator = tester.getTopLeft(find.text(kNotEncryptedAboveText)).dy;
    final note = tester.getTopLeft(find.text(kEncryptedNoteText)).dy;
    expect(tester.getTopLeft(find.text('m2')).dy, lessThan(separator));
    expect(separator, lessThan(note));
    expect(note, lessThan(tester.getTopLeft(find.text('secret')).dy));
  });

  testWidgets('no plaintext row is drawn while older encrypted rows exist or '
      'before any entry', (tester) async {
    final firstAt = kMsgBase.toUtc().add(const Duration(minutes: 1));
    await open(
      tester,
      hasMore: true,
      entries: [
        DecryptedMessage(id: 'e1', at: firstAt, mine: false, text: 'secret'),
      ],
    );
    expect(find.text('m2'), findsNothing);
    expect(find.text(kNotEncryptedAboveText), findsNothing);
    expect(find.text(kEncryptedNoteText), findsNothing);
  });

  testWidgets('no plaintext row is drawn before any encrypted entry', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('m2'), findsNothing);
    expect(find.text(kNotEncryptedAboveText), findsNothing);
  });

  testWidgets('the own-device alert sits between the messages around it in '
      'reading order', (tester) async {
    final handle = tester.ensureSemantics();
    await open(
      tester,
      entries: [
        entry(
          'e3',
          'message after the alert',
          after: const Duration(minutes: 2),
        ),
        SystemLineEntry(
          id: 'l1',
          at: base.add(const Duration(minutes: 1)),
          kind: SystemLineKind.deviceAdded,
          side: LineSide.mine,
        ),
        entry('e1', 'message before the alert'),
      ],
    );
    expect(find.byType(OwnDeviceAlert), findsOneWidget);
    final before = tester.getTopLeft(find.text('message before the alert')).dy;
    final alert = tester.getTopLeft(find.byType(OwnDeviceAlert)).dy;
    final after = tester.getTopLeft(find.text('message after the alert')).dy;
    expect(before, lessThan(alert));
    expect(alert, lessThan(after));

    // The accessibility traversal follows the same order.
    final nodes = tester.semantics.simulatedAccessibilityTraversal(
      startNode: find.semantics.byLabel(RegExp('message before the alert')),
      endNode: find.semantics.byLabel(RegExp('message after the alert')),
    );
    final labels = nodes.map((n) => n.label).toList();
    final i = labels.indexWhere((l) => l.contains(kOwnDeviceAlertTitle));
    expect(i, greaterThan(0));
    expect(labels.first, contains('message before the alert'));
    expect(labels.last, contains('message after the alert'));
    handle.dispose();
  });

  testWidgets('a retryable not-sent row retries through the port and the '
      'same row offers no report', (tester) async {
    final ctx = await open(
      tester,
      entries: [
        entry(
          'e1',
          'my text',
          mine: true,
          progress: SendProgress.notSent,
          problem: SendProblem.retryable,
        ),
      ],
    );
    await tester.tap(find.byKey(MessageBubble.statusKey));
    await tester.pumpAndSettle();
    expect(ctx.port.retried, ['e1']);
    // A retry row is always the caller's own, and a long press menu (Report)
    // exists only on a peer's row: the two never share a hit area.
    await tester.longPress(bubble('e1'));
    await tester.pumpAndSettle();
    expect(find.text(kReportMessageLabel), findsNothing);
    expect(ctx.port.retried.toSet(), {'e1'});
  });

  group('the request banner note', () {
    testWidgets('an encrypted request shows the encrypted note, never the '
        'not-encrypted one', (tester) async {
      await open(tester, request: true);
      expect(find.byType(RequestBanner), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RequestBanner),
          matching: find.text(kEncryptedNoteText),
        ),
        findsOneWidget,
      );
      expect(find.text(kMessagesNotEncryptedText), findsNothing);
    });

    testWidgets('an unknown encryption shows neither note', (tester) async {
      await open(
        tester,
        request: true,
        encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_UNSPECIFIED,
      );
      expect(find.byType(RequestBanner), findsOneWidget);
      expect(find.text(kEncryptedNoteText), findsNothing);
      expect(find.text(kMessagesNotEncryptedText), findsNothing);
    });

    testWidgets('a not-encrypted thread still shows the old note in the '
        'request banner', (tester) async {
      await open(tester, request: true, encryption: _none);
      expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
      expect(find.text(kEncryptedNoteText), findsNothing);
    });

    testWidgets('with no encrypted messaging the banner is today\'s', (
      tester,
    ) async {
      await open(
        tester,
        request: true,
        withPort: false,
        encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_UNSPECIFIED,
      );
      expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
    });
  });

  testWidgets('with the flag off and no vault the thread ignores the port '
      'entirely', (tester) async {
    final server = MessagingFlowRig.serverWithConversation();
    final port = FakeEncryptedMessaging();
    addTearDown(port.dispose);
    final device = FakeEncryptionDevice(vaultKnown: false, flag: E2eeFlag.off);
    final rig = MessagingFlowRig(server: server);
    await rig.pump(
      tester,
      location: AppRouter.messagePath(kThreadId),
      encrypted: port,
      device: device,
    );
    expect(find.text('m2'), findsOneWidget);
    expect(port.calls, isEmpty);
    expect(find.text(kEncryptedNoteText), findsNothing);
  });

  testWidgets('the plaintext rows keep today\'s text with the flag on and an '
      'unknown header', (tester) async {
    await open(
      tester,
      encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_UNSPECIFIED,
    );
    expect(find.text('m2'), findsOneWidget);
    expect(find.text('m1'), findsOneWidget);
    expect(find.text(kEncryptedNoteText), findsNothing);
    expect(Int64.ZERO, Int64.ZERO);
  });
}
