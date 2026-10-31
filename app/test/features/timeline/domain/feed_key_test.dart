import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:flutter_test/flutter_test.dart';

/// W3-16: a feed key names one cached feed and what the server binds its
/// tokens to (caller, target, effective tab), so every tab needs its own key.
void main() {
  test('W5-10: FeedKey.list is the drift key list:<id>, apart from Home and '
      'users', () {
    final key = FeedKey.list('7');
    expect(key.value, 'list:7');
    expect(key.listId, '7');
    expect(key.isList, isTrue);
    expect(key.isHome, isFalse);
    expect(key.userId, isNull);
    expect(key.tab, isNull);
    expect(key, FeedKey.list('7'));
    expect(key, isNot(FeedKey.list('8')));
    expect(key, isNot(const FeedKey.home()));
    expect(const FeedKey.home().isList, isFalse);
    expect(FeedKey.user('7').isList, isFalse);
  });

  test('Posts and Replies keep the drift keys written before the tab field '
      '(cached feeds and their tokens survive the upgrade)', () {
    expect(FeedKey.user('u1').value, 'user:u1:posts');
    expect(FeedKey.user('u1', includeReplies: true).value, 'user:u1:replies');
    expect(const FeedKey.home().value, 'home');
  });

  test('Reposts and Media get their own keys', () {
    expect(
      FeedKey.user('u1', tab: UserFeedTab.reposts).value,
      'user:u1:reposts',
    );
    expect(FeedKey.user('u1', tab: UserFeedTab.media).value, 'user:u1:media');
  });

  test('the four tabs of one user, and the same tab of two users, are all '
      'distinct feeds', () {
    final keys = <FeedKey>{
      for (final tab in UserFeedTab.values) FeedKey.user('u1', tab: tab),
      for (final tab in UserFeedTab.values) FeedKey.user('u2', tab: tab),
      const FeedKey.home(),
    };
    expect(keys, hasLength(UserFeedTab.values.length * 2 + 1));
    expect({
      for (final key in keys) key.value,
    }, hasLength(UserFeedTab.values.length * 2 + 1));
  });

  test('includeReplies and tab name the same cache', () {
    expect(
      FeedKey.user('u1', includeReplies: true),
      FeedKey.user('u1', tab: UserFeedTab.replies),
    );
    expect(FeedKey.user('u1'), FeedKey.user('u1', tab: UserFeedTab.posts));
    expect(
      FeedKey.user('u1', includeReplies: true).hashCode,
      FeedKey.user('u1', tab: UserFeedTab.replies).hashCode,
    );
  });

  test('a given tab wins over includeReplies, as the server tab wins over '
      'include_replies', () {
    final key = FeedKey.user(
      'u1',
      includeReplies: true,
      tab: UserFeedTab.media,
    );
    expect(key.tab, UserFeedTab.media);
    expect(key.includeReplies, isFalse);
    expect(key.value, 'user:u1:media');
  });

  test('home has no user and no tab; a user feed carries both', () {
    const home = FeedKey.home();
    expect(home.isHome, isTrue);
    expect(home.userId, isNull);
    expect(home.tab, isNull);
    expect(home.includeReplies, isFalse);

    final media = FeedKey.user('u1', tab: UserFeedTab.media);
    expect(media.isHome, isFalse);
    expect(media.userId, 'u1');
    expect(media.tab, UserFeedTab.media);
    expect(FeedKey.user('u1', includeReplies: true).includeReplies, isTrue);
  });

  test('only Reposts and Media need profile_tabs', () {
    expect(
      {
        for (final tab in UserFeedTab.values)
          if (tab.requiresProfileTabs) tab,
      },
      {UserFeedTab.reposts, UserFeedTab.media},
    );
  });
}

