import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/features/messages/presentation/conversations_screen.dart';
import 'package:dzeroth/features/messages/presentation/messages_list_detail.dart';
import 'package:dzeroth/features/messages/presentation/thread_screen.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import 'messaging_fixtures.dart';
import 'messaging_flow_rig.dart';

/// Messages with the tablet shell's two flags (and Block and Report).
const kMessagesTabletFlags = <String>{
  'messaging',
  'graph',
  'reports',
  kFeatureUiShell,
  kFeatureUiTablet,
};

/// The flag modes the tablet shell distinguishes (tablet plan section 2.3),
/// each with Messages on: only `ui_shell` + `ui_tablet` draws the tablet
/// layout.
const kMessagesFlagModes = <String, Set<String>>{
  'neither': {'messaging', 'graph', 'reports'},
  'ui_shell only': {'messaging', 'graph', 'reports', kFeatureUiShell},
  'ui_tablet only': {'messaging', 'graph', 'reports', kFeatureUiTablet},
  'ui_shell + ui_tablet': kMessagesTabletFlags,
};

/// The inbox of the tablet tests: [kTabletInboxCount] accepted
/// conversations, newest first, peer `Peer n` (`@peern`).
const kTabletInboxCount = 14;

String inboxId(int n) => hexId(0x100 + n);

/// The one message request (from Rex, @rex).
final String kRequestId = hexId(0x900);

/// A second request, so the Requests list has a row to switch to.
final String kRequestId2 = hexId(0x901);

String peerName(int n) => 'Peer $n';

/// A [FakeMessagingServer] with the tablet inbox, two requests, and two
/// messages in each conversation.
FakeMessagingServer tabletServer() {
  pb.Conversation row(
    String id, {
    required String name,
    required String handle,
    required int minutesAgo,
    Folder folder = Folder.FOLDER_INBOX,
  }) {
    final at = ts.Timestamp.fromDateTime(
      kMsgBase.subtract(Duration(minutes: minutesAgo)),
    );
    return pb.Conversation(
      id: id,
      kind: ConversationKind.CONVERSATION_KIND_DIRECT,
      peer: common.AuthorSnapshot(
        userId: 'u-$handle',
        handle: handle,
        displayName: name,
      ),
      state: folder == Folder.FOLDER_REQUESTS
          ? ConversationState.CONVERSATION_STATE_REQUEST
          : ConversationState.CONVERSATION_STATE_ACCEPTED,
      folder: folder,
      canReply: true,
      updatedAt: at,
      lastMessage: pb.MessagePreview(
        snippet: 'last from $handle',
        state: MessageState.MESSAGE_STATE_VISIBLE,
        createdAt: at,
      ),
    );
  }

  final server = FakeMessagingServer(
    conversations: [
      for (var n = 0; n < kTabletInboxCount; n++)
        row(inboxId(n), name: peerName(n), handle: 'peer$n', minutesAgo: n),
      row(
        kRequestId,
        name: 'Rex Request',
        handle: 'rex',
        minutesAgo: 1,
        folder: Folder.FOLDER_REQUESTS,
      ),
      row(
        kRequestId2,
        name: 'Ria Request',
        handle: 'ria',
        minutesAgo: 2,
        folder: Folder.FOLDER_REQUESTS,
      ),
    ],
  );
  var next = 1;
  for (final id in server.conversations.keys) {
    server.messages[id] = [
      msg(next++, conversationId: id, secondsAgo: 5, text: 'newer in $id'),
      msg(
        next++,
        conversationId: id,
        secondsAgo: 10,
        text: 'older in $id',
        fromSelf: true,
      ),
    ];
  }
  return server;
}

/// Band B's Messages list pane, or nothing.
Finder findMessagesPane() => find.byType(ConversationsListPane);

/// [finder] inside the list pane.
Finder inMessagesPane(Finder finder) =>
    find.descendant(of: findMessagesPane(), matching: finder);

/// The inbox row of conversation [id] (in whichever list).
Finder conversationRow(String id) => find.byKey(ValueKey('conversation-$id'));

/// The route child of `/messages` (the shell page), not the list pane.
Finder findInboxRoute() => find.byType(ConversationsScreen);

/// The `ThreadCubit` of the open thread.
ThreadCubit threadCubitOf(WidgetTester tester) => BlocProvider.of<ThreadCubit>(
  tester.element(
    find
        .descendant(
          of: find.byType(ThreadScreen),
          matching: find.byType(Scaffold),
        )
        .first,
  ),
);

/// The rect of [finder]'s first widget.
Rect rectOf(WidgetTester tester, Finder finder) => tester.getRect(finder.first);
