import 'package:dzeroth/features/messages/presentation/widgets/message_bubble.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:dzeroth/shared/widgets/post/embedded_post_card.dart';
import 'package:dzeroth/shared/widgets/post/unavailable_post_box.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/messaging_fixtures.dart';
import '../../../support/theme_harness.dart';

const _postId = '1234567890123456789';
const _url = 'https://dzeroth.com/post/$_postId';

posts.EmbeddedPost _card({bool unavailable = false}) => unavailable
    ? posts.EmbeddedPost(postId: _postId, unavailable: true)
    : posts.EmbeddedPost(
        postId: _postId,
        text: 'the original words',
        author: common.AuthorSnapshot(
          userId: 'u9',
          handle: 'writer',
          displayName: 'Wren Writer',
        ),
      );

pb.Message _shared({
  String text = _url,
  bool fromSelf = false,
  posts.EmbeddedPost? card,
  MessageState state = MessageState.MESSAGE_STATE_VISIBLE,
}) => msg(1, fromSelf: fromSelf, text: text)
  ..state = state
  ..sharedPost = card ?? _card();

void main() {
  Widget bubble(
    pb.Message message, {
    bool linksEnabled = true,
    void Function(String)? onOpenPost,
    void Function(Uri)? onOpenLink,
  }) => MessageBubble(
    message: message,
    peerName: 'Sam Rivera',
    now: kMsgBase.add(const Duration(minutes: 5)),
    firstOfGroup: true,
    lastOfGroup: true,
    linksEnabled: linksEnabled,
    onOpenLink: onOpenLink ?? (_) {},
    onOpenPost: onOpenPost,
  );

  group('a message that shares a post', () {
    testWidgets('draws the card and hides the text that is the post link', (
      tester,
    ) async {
      await pumpThemed(tester, bubble(_shared()));

      expect(find.byKey(kSharedPostCardKey), findsOneWidget);
      expect(find.byType(EmbeddedPostCard), findsOneWidget);
      expect(find.text('the original words'), findsOneWidget);
      expect(find.text('Wren Writer'), findsOneWidget);
      expect(find.textContaining('dzeroth.com'), findsNothing);
      expect(find.byType(MessageText), findsNothing);
    });

    testWidgets('hides the link whatever the origin is', (tester) async {
      await pumpThemed(
        tester,
        bubble(_shared(text: 'http://localhost:7357/post/$_postId')),
      );
      expect(find.byType(MessageText), findsNothing);
      expect(find.byKey(kSharedPostCardKey), findsOneWidget);
    });

    testWidgets('a caption stays above the card', (tester) async {
      await pumpThemed(tester, bubble(_shared(text: 'you will like this')));

      expect(find.text('you will like this'), findsOneWidget);
      expect(find.byKey(kSharedPostCardKey), findsOneWidget);
      final caption = tester.getTopLeft(find.text('you will like this')).dy;
      expect(
        caption,
        lessThan(tester.getTopLeft(find.byKey(kSharedPostCardKey)).dy),
      );
    });

    testWidgets('a caption that holds the link is still a caption', (
      tester,
    ) async {
      await pumpThemed(tester, bubble(_shared(text: 'see $_url')));
      expect(find.byType(MessageText), findsOneWidget);
      expect(find.byKey(kSharedPostCardKey), findsOneWidget);
    });

    testWidgets('the link of another post is not hidden', (tester) async {
      await pumpThemed(
        tester,
        bubble(_shared(text: 'https://dzeroth.com/post/9999999999999999999')),
      );
      expect(find.byType(MessageText), findsOneWidget);
    });

    testWidgets('an unavailable post is the one placeholder, no tap', (
      tester,
    ) async {
      String? opened;
      await pumpThemed(
        tester,
        bubble(
          _shared(card: _card(unavailable: true)),
          onOpenPost: (id) => opened = id,
        ),
      );

      expect(find.byType(UnavailablePostBox), findsOneWidget);
      expect(find.text('This post is unavailable'), findsOneWidget);
      expect(find.byType(MessageText), findsNothing);
      await tester.tap(find.byKey(kSharedPostCardKey));
      expect(opened, isNull);
    });

    testWidgets('tapping the card opens the post in the app', (tester) async {
      String? opened;
      await pumpThemed(
        tester,
        bubble(_shared(), onOpenPost: (id) => opened = id),
      );
      await tester.tap(find.byType(EmbeddedPostCard));
      expect(opened, _postId);
    });

    testWidgets('the card opens in a request that has not been accepted '
        '(links are off there, the in-app post is not a link)', (tester) async {
      String? opened;
      await pumpThemed(
        tester,
        bubble(_shared(), linksEnabled: false, onOpenPost: (id) => opened = id),
      );
      await tester.tap(find.byType(EmbeddedPostCard));
      expect(opened, _postId);
    });

    testWidgets('own bubble draws the card too', (tester) async {
      await pumpThemed(tester, bubble(_shared(fromSelf: true)));
      expect(find.byKey(kSharedPostCardKey), findsOneWidget);
    });

    for (final state in [
      MessageState.MESSAGE_STATE_DELETED_ACCOUNT,
      MessageState.MESSAGE_STATE_REMOVED,
    ]) {
      testWidgets('a tombstone ($state) has no card', (tester) async {
        await pumpThemed(tester, bubble(_shared(state: state, text: '')));
        expect(find.byKey(kSharedPostCardKey), findsNothing);
        expect(find.byType(EmbeddedPostCard), findsNothing);
      });
    }

    testWidgets('semantics: "shared a post", the card, never the link', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, bubble(_shared()));

      expect(
        find.bySemanticsLabel(
          'Sam Rivera shared a post, by Wren Writer, @writer, '
          'the original words, 5 minutes ago',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp('dzeroth.com')), findsNothing);
      handle.dispose();
    });

    testWidgets('semantics: own caption then the card', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        bubble(_shared(text: 'you will like this', fromSelf: true)),
      );
      expect(
        find.bySemanticsLabel(
          'You shared a post, you will like this, by Wren Writer, @writer, '
          'the original words',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('semantics: an unavailable card says so', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        bubble(_shared(card: _card(unavailable: true), fromSelf: true)),
      );
      expect(
        find.bySemanticsLabel('You shared a post, Post unavailable'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('assistive technology gets an "Open shared post" action', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      String? opened;
      await pumpThemed(
        tester,
        bubble(_shared(), onOpenPost: (id) => opened = id),
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('shared a post')),
      );
      expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
      expect(opened, isNull);
      handle.dispose();
    });

    for (final width in [360.0, 1024.0, 1440.0]) {
      testWidgets('no overflow at ${width.toInt()}dp, text scale 2', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          bubble(_shared(text: 'a caption that is a little longer than most')),
          size: Size(width, 800),
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(kSharedPostCardKey), findsOneWidget);
      });
    }
  });

  group('a client that predates the card (no shared_post on the message)', () {
    testWidgets('a text that is only the post link renders as a link', (
      tester,
    ) async {
      Uri? opened;
      await pumpThemed(
        tester,
        bubble(msg(1, text: _url), onOpenLink: (u) => opened = u),
      );

      expect(find.byKey(kSharedPostCardKey), findsNothing);
      expect(find.byType(MessageText), findsOneWidget);
      expect(find.text(_url), findsOneWidget);
      final spans = <TextSpan>[];
      tester
          .widget<RichText>(
            find
                .descendant(
                  of: find.byType(MessageText),
                  matching: find.byType(RichText),
                )
                .first,
          )
          .text
          .visitChildren((s) {
            if (s is TextSpan) spans.add(s);
            return true;
          });
      final link = spans.singleWhere((s) => s.recognizer != null);
      (link.recognizer! as TapGestureRecognizer).onTap!();
      expect(opened, Uri.parse(_url));
    });

    test('messageCaption keeps the text when there is no card', () {
      expect(messageCaption(msg(1, text: _url)), _url);
    });
  });

  group('messageTextIsPostLink', () {
    test('matches the path only, for the same post', () {
      expect(messageTextIsPostLink(_url, _postId), isTrue);
      expect(messageTextIsPostLink('  $_url  ', _postId), isTrue);
      expect(messageTextIsPostLink('$_url?x=1', _postId), isTrue);
    });

    test('does not match captions, other posts or a bare path', () {
      expect(messageTextIsPostLink('hi $_url', _postId), isFalse);
      expect(messageTextIsPostLink('$_url\nhi', _postId), isFalse);
      expect(messageTextIsPostLink('/post/$_postId', _postId), isFalse);
      expect(
        messageTextIsPostLink('https://dzeroth.com/post/1', _postId),
        isFalse,
      );
      expect(messageTextIsPostLink('', _postId), isFalse);
    });
  });
}
