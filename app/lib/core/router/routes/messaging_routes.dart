import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../features/messages/domain/messages_list_detail.dart';
import '../../../features/messages/presentation/draft_thread_screen.dart';
import '../../../features/messages/presentation/recipient_picker_screen.dart';
import '../../../features/messages/presentation/report_conversation.dart';
import '../../../features/messages/presentation/thread_route_page.dart';
import '../../../features/messages/presentation/thread_screen.dart';
import '../../../features/messages/presentation/widgets/message_composer.dart';
import '../../../features/messages/presentation/widgets/request_banner.dart';
import '../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart' show Folder;
import '../app_router.dart';

/// The root-navigator messaging routes: the people picker, the draft thread
/// and one conversation. Declared after the ShellRoute on purpose.
List<RouteBase> messagingRootRoutes() => [
  // The people picker (a dialog on the root navigator) and the
  // draft thread. Before `:id` on purpose, see `messagesPath`.
  GoRoute(
    path: AppRouter.messageNewPath,
    pageBuilder: (context, state) => RecipientPickerPage(key: state.pageKey),
  ),
  // The two thread routes stay root (tablet plan section 5.3): full
  // screen below 840dp and on desktop, the split page (rail, list,
  // thread) at 840-1199dp on the tablet layout. `ThreadRoutePage` keeps
  // the `AuthGate` outermost and the thread's state across 840dp.
  GoRoute(
    path: AppRouter.messageDraftPath,
    // A reload or a typed URL has no person: back to the picker.
    redirect: (context, state) =>
        state.extra is common.AuthorSnapshot ? null : AppRouter.messageNewPath,
    pageBuilder: (context, state) => _threadPage(
      state,
      ThreadRoutePage(
        location: state.matchedLocation,
        folder: Folder.FOLDER_INBOX,
        thread: DraftThreadScreen(peer: state.extra! as common.AuthorSnapshot),
      ),
    ),
  ),
  // One conversation, full-screen (no nav chrome under a composer).
  // After the ShellRoute on purpose, see `messagesPath`.
  GoRoute(
    path: '${AppRouter.messagesPath}/:id',
    pageBuilder: (context, state) => _threadPage(
      state,
      ThreadRoutePage(
        location: state.matchedLocation,
        // Opened from the Requests folder: its list beside the thread.
        folder: messagesSplitFolderOf(state.extra),
        thread: ThreadScreen(
          conversationId: state.pathParameters['id']!,
          // A message-search result opened this chat at one message.
          highlightMessageId: state.uri.queryParameters['m'],
          // The composer under the list (read-only threads and a
          // caller without `messaging` get none).
          composerBuilder: (context, conversation) => const MessageComposer(),
          // The request banner (Accept / Delete / Block) in place of
          // the composer, the sender's waiting note, and the info menu's
          // Report of the peer's account (the bubbles report messages).
          bannerBuilder: buildRequestBanner,
          onReport: reportConversationPeer,
        ),
      ),
    ),
  ),
];

/// The page of a thread route: [ThreadPage] at every width, with the
/// name, arguments and restoration id go_router gives its default pages.
Page<void> _threadPage(GoRouterState state, Widget child) => ThreadPage<void>(
  key: state.pageKey,
  name: state.name ?? state.path,
  arguments: <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  },
  restorationId: state.pageKey.value,
  child: child,
);
