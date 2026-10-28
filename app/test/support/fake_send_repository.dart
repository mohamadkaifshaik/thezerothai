import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/thread_poller.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;

import 'package:flutter_test/flutter_test.dart' show Fake;

import 'messaging_fixtures.dart';
import 'thread_test_support.dart';

/// A [MessagingRepository] with a tiny in-memory "server" for the composer
/// tests (W7-16): it stores one message per idempotency key (a retry with the
/// same key answers the stored one, as the real server does), can fail a send
/// before the server saw it ([failures]) or after it stored it
/// ([lostResponses], the dropped-response timeout), and can hold a send open
/// ([gate]).
class FakeSendRepository extends Fake implements MessagingRepository {
  /// What the thread cache holds (newest first).
  ThreadSnapshot thread = ThreadSnapshot(
    messages: const [],
    conversation: threadConv(),
    sinceToken: 's',
  );

  /// Every key a send carried, in order.
  final List<String> sendKeys = [];
  final List<String> sendTexts = [];

  /// The "server": one message per key.
  final Map<String, pb.Message> stored = {};

  /// Thrown by the next sends, before the server sees them.
  final List<Object> failures = [];

  /// Thrown by the next sends AFTER the server stored the message.
  final List<Object> lostResponses = [];

  /// Every `recipient_user_id` a send carried (null for a send to a
  /// conversation), in order (W7-17).
  final List<String?> sendRecipients = [];

  /// The conversation the "server" opens for a send that names a recipient.
  String createdConversationId = hexId(0xd1);

  /// Conversations the cache holds, by peer user id (W7-17).
  final Map<String, pb.Conversation> cachedByPeer = {};

  /// When set, a send waits for it (the "Sending…" state).
  Completer<void>? sendGate;

  @override
  RateLimitHold get rateLimitHold => RateLimitHold();

  @override
  RateLimitedException? rateLimitedFor() => null;

  @override
  Future<pb.Conversation?> cachedConversationWith(String peerUserId) async =>
      cachedByPeer[peerUserId];

  @override
  Future<ThreadSnapshot> cachedThread(String conversationId) async => thread;

  @override
  Future<ThreadSnapshot> refreshThread(String conversationId) async => thread;

  @override
  Future<PollResult> pollThread(String conversationId) async =>
      const PollResult(newMessages: false);

  @override
  Future<void> markConversationRead({
    required String idempotencyKey,
    required String conversationId,
  }) async {}

  @override
  Future<pb.SendMessageResponse> sendMessage({
    required String idempotencyKey,
    required String text,
    String? conversationId,
    String? recipientUserId,
  }) async {
    sendKeys.add(idempotencyKey);
    sendTexts.add(text);
    sendRecipients.add(recipientUserId);
    final wait = sendGate;
    if (wait != null) await wait.future;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    final message = stored.putIfAbsent(
      idempotencyKey,
      () => msg(
        1000 + stored.length,
        fromSelf: true,
        text: text,
        conversationId: conversationId ?? createdConversationId,
      ),
    );
    if (lostResponses.isNotEmpty) throw lostResponses.removeAt(0);
    // The repository caches a sent message on success only.
    if (!thread.messages.any((m) => m.id == message.id)) {
      thread = ThreadSnapshot(
        messages: [message, ...thread.messages],
        conversation: thread.conversation,
        sinceToken: thread.sinceToken,
        olderPageToken: thread.olderPageToken,
      );
    }
    return pb.SendMessageResponse(
      message: message,
      conversation: recipientUserId == null
          ? null
          : threadConv(id: createdConversationId),
    );
  }
}
