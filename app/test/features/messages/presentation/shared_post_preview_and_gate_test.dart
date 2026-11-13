import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_gate.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';

const _url = 'https://dzeroth.com/post/1234567890123456789';

void main() {
  group('inbox preview of a shared post', () {
    String snippetOf({
      required String snippet,
      bool shared = true,
      bool fromSelf = false,
      MessageState state = MessageState.MESSAGE_STATE_VISIBLE,
    }) {
      final c = conv(
        'a',
        snippet: snippet,
        fromSelf: fromSelf,
        lastState: state,
      );
      c.lastMessage.sharedPost = shared;
      return conversationSnippet(c);
    }

    test('no caption: "Shared a post" instead of the link', () {
      expect(snippetOf(snippet: _url), 'Shared a post');
    });

    test('the caller\'s own share keeps the "You: " prefix', () {
      expect(snippetOf(snippet: _url, fromSelf: true), 'You: Shared a post');
    });

    test('a link cut short by the preview is still the link', () {
      expect(snippetOf(snippet: 'https://dzeroth.com/po…'), 'Shared a post');
    });

    test('an empty snippet of a share is "Shared a post"', () {
      expect(snippetOf(snippet: ''), 'Shared a post');
    });

    test('a caption stays the preview', () {
      expect(snippetOf(snippet: 'you will like this'), 'you will like this');
      expect(snippetOf(snippet: 'see $_url', fromSelf: true), 'You: see $_url');
    });

    test('a plain message that is only a link is not rewritten', () {
      expect(snippetOf(snippet: _url, shared: false), _url);
    });

    test('a tombstone wins over the share', () {
      expect(
        snippetOf(snippet: '', state: MessageState.MESSAGE_STATE_REMOVED),
        kConversationRemovedSnippet,
      );
      expect(
        snippetOf(
          snippet: '',
          state: MessageState.MESSAGE_STATE_DELETED_ACCOUNT,
        ),
        kConversationDeletedSnippet,
      );
    });

    test('never carries the post text: the preview has none to show', () {
      expect(snippetOf(snippet: _url), isNot(contains('post/')));
    });
  });

  group('the messaging gate and a dm_post_share refusal', () {
    test('does not turn plain sends off', () async {
      final gate = MessagingFeatureGate(isMessagingEnabled: () => true);
      await expectLater(
        gate.run<void>(
          () async => throw const FeatureDisabledException(
            'off',
            feature: kFeatureDmPostShare,
          ),
        ),
        throwsA(isA<FeatureDisabledException>()),
      );

      expect(gate.canSend, isTrue);
      // A plain send still goes out.
      expect(await gate.run(() async => 7), 7);
    });

    test('a FEATURE_DISABLED for messaging itself still does', () async {
      final gate = MessagingFeatureGate(isMessagingEnabled: () => true);
      await expectLater(
        gate.run<void>(() async => throw const FeatureDisabledException('off')),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(gate.canSend, isFalse);
    });
  });
}
