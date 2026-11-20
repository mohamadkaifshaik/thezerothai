import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/widgets/conversation_row.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/messaging_fixtures.dart';

/// A row whose last message the server marked encrypted (its snippet is the
/// server's, which an encrypted row must never show).
pb.Conversation _encrypted({bool fromSelf = false, String snippet = ''}) =>
    conv('a', snippet: snippet, fromSelf: fromSelf)
      ..lastMessage.encrypted = true;

void main() {
  group('an encrypted row takes its second line from the preview', () {
    final cases = <PreviewKind, ({String text, ConversationPreview preview})>{
      PreviewKind.text: (
        text: 'see you at 6',
        preview: const ConversationPreview(
          kind: PreviewKind.text,
          text: 'see you at 6',
        ),
      ),
      PreviewKind.sharedPost: (
        text: kConversationSharedPostSnippet,
        preview: const ConversationPreview(kind: PreviewKind.sharedPost),
      ),
      PreviewKind.removed: (
        text: kConversationRemovedSnippet,
        preview: const ConversationPreview(kind: PreviewKind.removed),
      ),
      PreviewKind.deletedAccount: (
        text: kConversationDeletedSnippet,
        preview: const ConversationPreview(kind: PreviewKind.deletedAccount),
      ),
      PreviewKind.undecryptable: (
        text: kCouldNotDecryptText,
        preview: const ConversationPreview(kind: PreviewKind.undecryptable),
      ),
      PreviewKind.unverified: (
        text: kCouldNotVerifyText,
        preview: const ConversationPreview(kind: PreviewKind.unverified),
      ),
      PreviewKind.undecodable: (
        text: kCannotDisplayText,
        preview: const ConversationPreview(kind: PreviewKind.undecodable),
      ),
      PreviewKind.generic: (
        text: kEncryptedPlaceholderText,
        preview: const ConversationPreview(kind: PreviewKind.generic),
      ),
    };
    for (final kind in PreviewKind.values) {
      test(kind.name, () {
        final c = cases[kind]!;
        expect(conversationSnippet(_encrypted(), preview: c.preview), c.text);
      });
    }
  });

  test('mine adds "You: " except for generic and undecryptable', () {
    for (final kind in PreviewKind.values) {
      final preview = ConversationPreview(
        kind: kind,
        text: kind == PreviewKind.text ? 'on my way' : '',
        mine: true,
      );
      final line = conversationSnippet(_encrypted(), preview: preview);
      final prefixed =
          kind != PreviewKind.generic && kind != PreviewKind.undecryptable;
      expect(
        line.startsWith(kConversationSelfPrefix),
        prefixed,
        reason: kind.name,
      );
    }
    expect(
      conversationSnippet(
        _encrypted(),
        preview: const ConversationPreview(
          kind: PreviewKind.text,
          text: 'on my way',
          mine: true,
        ),
      ),
      'You: on my way',
    );
  });

  test('an encrypted row without a preview is "Encrypted message"', () {
    expect(conversationSnippet(_encrypted()), kEncryptedPlaceholderText);
    // The sender's side (from_self) never adds a prefix without a preview.
    expect(
      conversationSnippet(_encrypted(fromSelf: true)),
      kEncryptedPlaceholderText,
    );
    // A text preview with no text is never a blank row.
    expect(
      conversationSnippet(
        _encrypted(),
        preview: const ConversationPreview(kind: PreviewKind.text),
      ),
      kEncryptedPlaceholderText,
    );
  });

  test('a row the vault knows ignores the server snippet', () {
    final row = conv('a', snippet: 'server words'); // encrypted = false
    expect(
      conversationSnippet(row, knownEncrypted: true),
      kEncryptedPlaceholderText,
    );
    expect(
      conversationSnippet(
        row,
        knownEncrypted: true,
        preview: const ConversationPreview(
          kind: PreviewKind.text,
          text: 'vault words',
        ),
      ),
      'vault words',
    );
  });

  test('a plaintext row ignores a preview and is unchanged', () {
    const preview = ConversationPreview(
      kind: PreviewKind.text,
      text: 'vault words',
      mine: true,
    );
    expect(
      conversationSnippet(conv('a', snippet: 'plain'), preview: preview),
      'plain',
    );
    expect(
      conversationSnippet(
        conv('a', snippet: 'plain', fromSelf: true),
        preview: preview,
      ),
      'You: plain',
    );
    expect(conversationSnippet(conv('a')), '');
  });
}
