import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_status.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/widgets/conversation_encryption_note.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart'
    show kMessagingReadOnlyText;
import 'package:flutter_bloc/flutter_bloc.dart';
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
    VaultStatus vault = VaultStatus.ready,
    bool vaultKnown = true,
    bool engineUnavailable = false,
    bool removedElsewhere = false,
    bool withStatus = true,
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
    port.removedElsewhere.value = removedElsewhere;
    final device = FakeEncryptionDevice(status: vault, vaultKnown: vaultKnown);
    device.engineUnavailable.value = engineUnavailable;
    final status = EncryptionStatusCubit(
      device: device,
      messaging: port,
      flagOn: () => extraFlags.contains(kFeatureE2eeDm),
    );
    addTearDown(status.close);
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
      extraBlocs: [
        if (withPort && withStatus)
          BlocProvider<EncryptionStatusCubit>.value(value: status),
      ],
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

  // ---------------------------------------------------------------- part 2
  Finder composer() => find.byKey(MessageComposer.fieldKey);
  Finder blockButton() => find.text('Block');
  Finder reset() => find.text(kConversationResetAction);

  List<String> allTexts(WidgetTester tester) => [
    for (final t in tester.widgetList<Text>(find.byType(Text)))
      t.data ?? t.textSpan?.toPlainText() ?? '',
  ];

  ConversationSecurity sec(
    ConversationEncryptionState state, {
    bool canSend = true,
    bool canReset = false,
    bool sentRequest = false,
  }) => ConversationSecurity(
    state: state,
    canSend: canSend,
    canReset: canReset,
    sentRequest: sentRequest,
  );

  group('conversation states', () {
    final rows =
        <
          ({
            String name,
            ConversationSecurity security,
            List<String> texts,
            bool composer,
            bool reset,
            bool block,
          })
        >[
          for (final st in [
            ConversationEncryptionState.ready,
            ConversationEncryptionState.syncing,
            ConversationEncryptionState.sendPaused,
            ConversationEncryptionState.pendingRequest,
          ])
            (
              name: '$st shows no notice and the composer',
              security: sec(st),
              texts: const [],
              composer: true,
              reset: false,
              block: false,
            ),
          (
            name: 'listUnverifiable: notice above the composer',
            security: sec(ConversationEncryptionState.listUnverifiable),
            texts: const [
              kStateListUnverifiableTitle,
              kStateListUnverifiableBody,
            ],
            composer: true,
            reset: false,
            block: false,
          ),
          (
            name: 'peerHasNoDevice replaces the composer',
            security: sec(
              ConversationEncryptionState.peerHasNoDevice,
              canSend: false,
            ),
            texts: const [kStatePeerNoDeviceText],
            composer: false,
            reset: false,
            block: false,
          ),
          (
            name: 'waitingForDevice, canReset',
            security: sec(
              ConversationEncryptionState.waitingForDevice,
              canSend: false,
              canReset: true,
            ),
            texts: const [kStateWaitingTitle, kStateWaitingBody],
            composer: false,
            reset: true,
            block: false,
          ),
          (
            name: 'waitingForDevice, no reset',
            security: sec(
              ConversationEncryptionState.waitingForDevice,
              canSend: false,
            ),
            texts: const [kStateWaitingTitle, kStateWaitingBody],
            composer: false,
            reset: false,
            block: false,
          ),
          (
            name: 'stuck, canReset',
            security: sec(
              ConversationEncryptionState.stuck,
              canSend: false,
              canReset: true,
            ),
            texts: const [kStateStuckTitle, kStateStuckBodyCanReset],
            composer: false,
            reset: true,
            block: false,
          ),
          (
            name: 'stuck, no reset',
            security: sec(ConversationEncryptionState.stuck, canSend: false),
            texts: const [kStateStuckTitle, kStateStuckBodyNoReset],
            composer: false,
            reset: false,
            block: false,
          ),
          (
            name: 'unknownDevice',
            security: sec(
              ConversationEncryptionState.unknownDevice,
              canSend: false,
            ),
            texts: const [kLineUnknownDevice, kStateUnknownDeviceBody],
            composer: false,
            reset: false,
            block: false,
          ),
          (
            name: 'changesBlocked, canSend false, canReset',
            security: sec(
              ConversationEncryptionState.changesBlocked,
              canSend: false,
              canReset: true,
            ),
            texts: const [kStateBlockedTitle, kStateBlockedBodyCanReset],
            composer: false,
            reset: true,
            block: true,
          ),
          (
            name: 'changesBlocked, canSend false, no reset',
            security: sec(
              ConversationEncryptionState.changesBlocked,
              canSend: false,
            ),
            texts: const [kStateBlockedTitle, kStateBlockedBodyNoReset],
            composer: false,
            reset: false,
            block: true,
          ),
          (
            name: 'changesBlocked, canSend true, canReset',
            security: sec(
              ConversationEncryptionState.changesBlocked,
              canReset: true,
            ),
            texts: const [kStateBlockedCanSendTitle, kStateBlockedCanSendBody],
            composer: true,
            reset: true,
            block: true,
          ),
          (
            name: 'changesBlocked, canSend true, no reset',
            security: sec(ConversationEncryptionState.changesBlocked),
            texts: const [kStateBlockedCanSendTitle, kStateBlockedCanSendBody],
            composer: true,
            reset: false,
            block: true,
          ),
        ];
    for (final row in rows) {
      testWidgets(row.name, (tester) async {
        await open(
          tester,
          entries: [entry('e1', 'hi')],
          security: row.security,
        );
        for (final t in row.texts) {
          expect(find.text(t), findsOneWidget, reason: t);
        }
        expect(composer(), row.composer ? findsOneWidget : findsNothing);
        expect(reset(), row.reset ? findsOneWidget : findsNothing);
        expect(blockButton(), row.block ? findsOneWidget : findsNothing);
        if (row.composer && row.texts.isNotEmpty) {
          expect(
            tester.getTopLeft(find.text(row.texts.first)).dy,
            lessThan(tester.getTopLeft(composer()).dy),
            reason: 'the notice sits above the composer',
          );
        }
        if (!row.composer) {
          expect(find.text(kMessagingReadOnlyText), findsNothing);
        }
      });
    }

    testWidgets('changesBlocked with canSend false and an unknown-device line '
        'shows the M5 notice, not the unknown-device notice', (tester) async {
      await open(
        tester,
        entries: [
          entry('e1', 'hi'),
          SystemLineEntry(
            id: 'l1',
            at: base.add(const Duration(minutes: 1)),
            kind: SystemLineKind.unknownDevice,
            side: LineSide.unattributed,
          ),
        ],
        security: sec(
          ConversationEncryptionState.changesBlocked,
          canSend: false,
          canReset: true,
        ),
      );
      expect(find.text(kStateBlockedTitle), findsOneWidget);
      expect(find.text(kStateUnknownDeviceBody), findsNothing);
      expect(blockButton(), findsOneWidget);
      expect(reset(), findsOneWidget);
      expect(composer(), findsNothing);
    });

    testWidgets('changesBlocked with canSend true never says an unknown '
        'device is present and never says kStateBlockedTitle', (tester) async {
      await open(
        tester,
        entries: [entry('e1', 'hi')],
        security: sec(ConversationEncryptionState.changesBlocked),
      );
      expect(find.text(kStateBlockedCanSendTitle), findsOneWidget);
      expect(find.text(kStateBlockedTitle), findsNothing);
      expect(find.text(kStateBlockedBodyCanReset), findsNothing);
      expect(find.text(kStateBlockedBodyNoReset), findsNothing);
      for (final t in allTexts(tester)) {
        expect(t.toLowerCase(), isNot(contains('unknown device')));
      }
    });

    for (final st in ConversationEncryptionState.values) {
      for (final canSend in [true, false]) {
        testWidgets('the composer follows canSend, not the state: $st '
            'canSend=$canSend', (tester) async {
          await open(
            tester,
            entries: [entry('e1', 'hi')],
            security: sec(st, canSend: canSend),
          );
          expect(composer(), canSend ? findsOneWidget : findsNothing);
        });
      }
    }

    testWidgets('a canSend false state without a notice shows the read-only '
        'line', (tester) async {
      await open(
        tester,
        entries: [entry('e1', 'hi')],
        security: sec(ConversationEncryptionState.ready, canSend: false),
      );
      expect(composer(), findsNothing);
      expect(find.text(kMessagingReadOnlyText), findsOneWidget);
    });

    testWidgets('changesBlocked with canSend false never offers a send '
        'action', (tester) async {
      await open(
        tester,
        entries: [entry('e1', 'hi')],
        security: sec(
          ConversationEncryptionState.changesBlocked,
          canSend: false,
          canReset: true,
        ),
      );
      expect(find.textContaining('anyway'), findsNothing);
      expect(find.textContaining('Send'), findsNothing);
      expect(composer(), findsNothing);
    });

    testWidgets('a first message thread with a peer whose list is empty is a '
        'plain thread', (tester) async {
      await open(tester, encryption: _none, entries: const []);
      expect(find.text(kStatePeerNoDeviceText), findsNothing);
      expect(find.text('m2'), findsOneWidget);
      expect(composer(), findsOneWidget);
    });

    testWidgets('a device waiting to be added that opens from the cache and '
        'gets only since responses still shows the waiting notice', (
      tester,
    ) async {
      await open(
        tester,
        encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_UNSPECIFIED,
        security: sec(
          ConversationEncryptionState.waitingForDevice,
          canSend: false,
          canReset: true,
        ),
        tweak: (server) {
          // The cached row says encrypted; the header never does.
          server.conversations[kThreadId]!.lastMessage.encrypted = true;
        },
      );
      expect(find.text(kStateWaitingTitle), findsOneWidget);
      expect(composer(), findsNothing);
    });

    testWidgets('a GetKeyDevices rate limit produces no notice', (
      tester,
    ) async {
      await open(tester, entries: [entry('e1', 'hi')]);
      expect(find.text(kStateListUnverifiableTitle), findsNothing);
      expect(find.text(kStateBlockedTitle), findsNothing);
      expect(composer(), findsOneWidget);
    });
  });

  group('reset encryption', () {
    final stuck = sec(
      ConversationEncryptionState.stuck,
      canSend: false,
      canReset: true,
    );

    testWidgets('asks first and calls the port only on confirm', (
      tester,
    ) async {
      final ctx = await open(tester, security: stuck);
      await tester.tap(reset());
      await tester.pumpAndSettle();
      expect(find.text(kConversationResetTitle), findsOneWidget);
      expect(find.text(kConversationResetMessage), findsOneWidget);
      expect(ctx.port.resetConversations, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(ctx.port.resetConversations, isEmpty);

      await tester.tap(reset());
      await tester.pumpAndSettle();
      await tester.tap(find.text(kConversationResetConfirm));
      await tester.pumpAndSettle();
      expect(ctx.port.resetConversations, [kThreadId]);
    });

    testWidgets('a refusal is said in a snackbar by its reason', (
      tester,
    ) async {
      final ctx = await open(tester, security: stuck);
      ctx.port.failNextOn(
        'resetConversation',
        const ResetRefusedException(ResetRefusal.notAccepted),
      );
      await tester.tap(reset());
      await tester.pumpAndSettle();
      await tester.tap(find.text(kConversationResetConfirm));
      await tester.pumpAndSettle();
      expect(find.text(kConversationResetNotAcceptedText), findsOneWidget);
    });

    testWidgets('a peer without a device is said by its reason', (
      tester,
    ) async {
      final ctx = await open(tester, security: stuck);
      ctx.port.failNextOn(
        'resetConversation',
        const ResetRefusedException(ResetRefusal.peerHasNoDevice),
      );
      await tester.tap(reset());
      await tester.pumpAndSettle();
      await tester.tap(find.text(kConversationResetConfirm));
      await tester.pumpAndSettle();
      expect(find.text(kStatePeerNoDeviceText), findsOneWidget);
    });

    for (final st in [
      ConversationEncryptionState.waitingForDevice,
      ConversationEncryptionState.stuck,
      ConversationEncryptionState.changesBlocked,
    ]) {
      testWidgets('Reset encryption is absent when canReset is false in $st', (
        tester,
      ) async {
        await open(tester, security: sec(st, canSend: false));
        expect(reset(), findsNothing);
      });
    }
  });

  group('message requests', () {
    void sentRequest(dynamic server) {
      server.conversations[kThreadId]!
        ..state = ConversationState.CONVERSATION_STATE_REQUEST
        ..folder = Folder.FOLDER_INBOX;
    }

    final line = SystemLineEntry(
      id: 'l1',
      at: DateTime.now().toUtc().add(const Duration(hours: 1, minutes: 1)),
      kind: SystemLineKind.deviceAdded,
      side: LineSide.mine,
    );

    for (final canReset in [false, true]) {
      testWidgets('a sent request never offers Reset encryption, even stuck, '
          'with canReset $canReset', (tester) async {
        await open(
          tester,
          tweak: sentRequest,
          security: sec(
            ConversationEncryptionState.stuck,
            canSend: false,
            canReset: canReset,
            sentRequest: true,
          ),
        );
        expect(reset(), findsNothing);
      });
    }

    testWidgets('a sent request hides lines and keeps the messages', (
      tester,
    ) async {
      await open(
        tester,
        tweak: sentRequest,
        entries: [
          entry('e2', 'later', after: const Duration(minutes: 2)),
          line,
        ],
        security: sec(ConversationEncryptionState.ready, sentRequest: true),
      );
      expect(find.text('later'), findsOneWidget);
      expect(find.byType(OwnDeviceAlert), findsNothing);
      expect(find.text(kSentRequestText), findsOneWidget);
    });

    testWidgets('pendingRequest shows no line, no alert and no notice even '
        'when entries contain them', (tester) async {
      await open(
        tester,
        request: true,
        entries: [
          entry('e2', 'later', after: const Duration(minutes: 2)),
          line,
          SystemLineEntry(
            id: 'l2',
            at: base.add(const Duration(minutes: 1)),
            kind: SystemLineKind.unknownDevice,
            side: LineSide.unattributed,
          ),
        ],
        security: sec(
          ConversationEncryptionState.pendingRequest,
          canSend: false,
        ),
      );
      expect(find.byType(OwnDeviceAlert), findsNothing);
      expect(find.text(kLineUnknownDevice), findsNothing);
      expect(find.text(kStateWaitingTitle), findsNothing);
      expect(find.byType(RequestBanner), findsOneWidget);
    });

    testWidgets('Accept calls the existing accept; nothing else does', (
      tester,
    ) async {
      final ctx = await open(
        tester,
        request: true,
        security: sec(ConversationEncryptionState.pendingRequest),
      );
      const accept =
          '/dzeroth.messaging.v1.MessagingService/AcceptMessageRequest';
      expect(ctx.rig.server.count(accept), 0);
      await tester.tap(find.byKey(RequestBanner.acceptKey));
      await tester.pumpAndSettle();
      expect(ctx.rig.server.count(accept), 1);
    });
  });

  group('no usable vault', () {
    testWidgets('MLS header on an unsupported platform: placeholders, the '
        'notice, no composer, no Report', (tester) async {
      await open(tester, vault: VaultStatus.unsupported);
      expect(find.text('m2'), findsNothing);
      expect(find.text(kEncryptedPlaceholderText), findsWidgets);
      expect(find.text(kNotOnThisDeviceText), findsOneWidget);
      expect(composer(), findsNothing);
      await tester.longPress(
        find.byKey(const ValueKey('bubble-00000000000000000000000000000002')),
      );
      await tester.pumpAndSettle();
      expect(find.text(kReportMessageLabel), findsNothing);
    });

    testWidgets('MLS header with the flag off and no vault: the same notice', (
      tester,
    ) async {
      await open(
        tester,
        extraFlags: const {},
        vault: VaultStatus.off,
        vaultKnown: false,
      );
      expect(find.text(kNotOnThisDeviceText), findsOneWidget);
      expect(find.text(kEncryptedPlaceholderText), findsWidgets);
      expect(composer(), findsNothing);
    });

    testWidgets('server text is never drawn in an encrypted thread without a '
        'vault, even with mlsGeneration 0', (tester) async {
      await open(
        tester,
        vault: VaultStatus.unsupported,
        tweak: (server) {
          server.messages[kThreadId]!.insert(
            0,
            msg(
              3,
              conversationId: kThreadId,
              secondsAgo: 1,
              text: 'server plaintext',
            ),
          );
        },
      );
      expect(find.text('server plaintext'), findsNothing);
      expect(find.text('m1'), findsNothing);
    });

    testWidgets('vault keyLost: the status card replaces the composer with '
        'Try again', (tester) async {
      await open(tester, vault: VaultStatus.keyLost);
      expect(composer(), findsNothing);
      expect(find.text(kStatusTryAgain), findsOneWidget);
      expect(find.text(kEncryptedPlaceholderText), findsWidgets);
      expect(find.text('m2'), findsNothing);
    });

    testWidgets('a vault that closes mid-thread stops drawing decrypted '
        'text', (tester) async {
      final ctx = await open(tester, entries: [entry('e1', 'secret words')]);
      expect(find.text('secret words'), findsOneWidget);
      ctx.device.vaultStatus.value = VaultStatus.unavailable;
      await tester.pumpAndSettle();
      expect(find.text('secret words'), findsNothing);
      expect(composer(), findsNothing);
    });

    testWidgets('removedElsewhere: messages stay, the composer is the card', (
      tester,
    ) async {
      await open(
        tester,
        entries: [entry('e1', 'still readable')],
        removedElsewhere: true,
      );
      expect(find.text('still readable'), findsOneWidget);
      expect(composer(), findsNothing);
      expect(find.text(kStatusRemovedTitle), findsOneWidget);
    });

    testWidgets('engineUnavailable: messages stay, the card replaces the '
        'composer', (tester) async {
      await open(
        tester,
        entries: [entry('e1', 'still readable')],
        engineUnavailable: true,
      );
      expect(find.text('still readable'), findsOneWidget);
      expect(composer(), findsNothing);
      expect(find.text(kStatusEngineUnavailableTitle), findsOneWidget);
    });

    testWidgets('a received request with no vault keeps the request banner', (
      tester,
    ) async {
      await open(tester, request: true, vault: VaultStatus.unsupported);
      expect(find.byType(RequestBanner), findsOneWidget);
      expect(find.text(kNotOnThisDeviceText), findsNothing);
    });
  });

  group('the status banner in every thread', () {
    testWidgets('a plaintext thread shows it above the composer while the '
        'vault blocks messaging', (tester) async {
      await open(tester, encryption: _none, vault: VaultStatus.unavailable);
      expect(find.text(kStatusDetails), findsOneWidget);
      expect(composer(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(kStatusDetails)).dy,
        lessThan(tester.getTopLeft(composer()).dy),
      );
      expect(find.text('m2'), findsOneWidget);
    });

    testWidgets('an unknown-encryption thread shows it too', (tester) async {
      await open(
        tester,
        encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_UNSPECIFIED,
        vault: VaultStatus.opening,
      );
      expect(find.text(kStatusOpeningText), findsOneWidget);
      expect(composer(), findsOneWidget);
    });

    testWidgets('it is absent while nothing blocks messaging', (tester) async {
      await open(tester, encryption: _none);
      expect(find.text(kStatusDetails), findsNothing);
    });

    testWidgets('with no status in the tree nothing is added', (tester) async {
      await open(
        tester,
        encryption: _none,
        vault: VaultStatus.unavailable,
        withStatus: false,
      );
      expect(find.text(kStatusDetails), findsNothing);
      expect(composer(), findsOneWidget);
    });

    testWidgets('a not-encrypted thread of a user with access full shows the '
        'not-encrypted note above the composer', (tester) async {
      await open(tester, encryption: _none);
      expect(find.text(kMessagesNotEncryptedText), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(kMessagesNotEncryptedText)).dy,
        lessThan(tester.getTopLeft(composer()).dy),
      );
    });

    testWidgets('a draft thread shows it above its composer too', (
      tester,
    ) async {
      final device = FakeEncryptionDevice(status: VaultStatus.unavailable);
      final port = FakeEncryptedMessaging();
      addTearDown(port.dispose);
      final status = EncryptionStatusCubit(
        device: device,
        messaging: port,
        flagOn: () => true,
      );
      addTearDown(status.close);
      final rig = MessagingFlowRig(
        server: MessagingFlowRig.serverWithConversation(),
        flags: {'messaging', 'graph', kFeatureE2eeDm},
      );
      await rig.pump(
        tester,
        encrypted: port,
        device: device,
        extraBlocs: [BlocProvider<EncryptionStatusCubit>.value(value: status)],
      );
      unawaited(
        rig.appRouter.router.push<void>(
          AppRouter.messageDraftPath,
          extra: common.AuthorSnapshot(
            userId: 'u-sam',
            handle: 'sam',
            displayName: 'Sam Rivera',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(kStatusDetails), findsOneWidget);
      expect(composer(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(kStatusDetails)).dy,
        lessThan(tester.getTopLeft(composer()).dy),
      );
    });

    testWidgets('access manage shows no such note', (tester) async {
      await open(tester, encryption: _none, extraFlags: const {});
      expect(find.text(kMessagesNotEncryptedText), findsNothing);
    });
  });
}
