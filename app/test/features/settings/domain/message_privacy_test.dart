import 'package:dzeroth/features/notifications/domain/notification_prefs.dart';
import 'package:dzeroth/features/settings/data/own_privacy_store.dart';
import 'package:dzeroth/features/settings/domain/message_privacy.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wire names match the server flags', () {
    expect(kFeatureReadReceipts, 'read_receipts');
    expect(kFeatureDmPolicy, 'dm_policy');
    expect(kFeatureNotificationPrefs, 'notification_prefs');
  });

  group('read receipts row (undo rule)', () {
    for (final (flag, messaging, value, refused, visible) in [
      (true, true, false, false, true),
      (false, true, false, false, false),
      (true, false, false, false, false),
      (true, true, false, true, false),
      // On: always shown, so it can be turned off.
      (false, false, true, false, true),
      (false, true, true, true, true),
    ]) {
      test('flag $flag, messaging $messaging, on $value, refused $refused', () {
        expect(
          readReceiptsRowVisible(
            flagOn: flag,
            messagingOn: messaging,
            value: value,
            refused: refused,
          ),
          visible,
        );
      });
    }
  });

  group('who can message row (undo rule)', () {
    for (final (flag, messaging, value, refused, visible) in [
      (true, true, WhoCanMessage.everyone, false, true),
      (false, true, WhoCanMessage.everyone, false, false),
      (true, false, WhoCanMessage.everyone, false, false),
      (true, true, WhoCanMessage.everyone, true, false),
      (false, false, WhoCanMessage.following, false, true),
      (false, true, WhoCanMessage.following, true, true),
    ]) {
      test('flag $flag, messaging $messaging, $value, refused $refused', () {
        expect(
          whoCanMessageRowVisible(
            flagOn: flag,
            messagingOn: messaging,
            value: value,
            refused: refused,
          ),
          visible,
        );
      });
    }
  });

  group('wire mapping', () {
    test('UNSPECIFIED and EVERYONE_REQUESTS are Everyone', () {
      expect(
        whoCanMessageOf(identity.DmPolicy.DM_POLICY_UNSPECIFIED),
        WhoCanMessage.everyone,
      );
      expect(
        whoCanMessageOf(identity.DmPolicy.DM_POLICY_EVERYONE_REQUESTS),
        WhoCanMessage.everyone,
      );
      expect(
        whoCanMessageOf(identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY),
        WhoCanMessage.following,
      );
    });

    test('UNSPECIFIED is never sent', () {
      for (final who in WhoCanMessage.values) {
        expect(dmPolicyOf(who), isNot(identity.DmPolicy.DM_POLICY_UNSPECIFIED));
      }
    });

    test('the store records only the privacy part; clear forgets it', () {
      final store = OwnPrivacyStore();
      store.record(identity.Profile());
      expect(store.value, isNull, reason: 'no user id: nothing recorded');
      store.record(
        identity.Profile(
          userId: 'me',
          readReceipts: true,
          dmPolicy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY,
        ),
      );
      expect(
        store.value,
        const OwnPrivacy(
          userId: 'me',
          readReceipts: true,
          whoCanMessage: WhoCanMessage.following,
        ),
      );
      expect(store.value.toString(), isNot(contains('me')));
      store.clear();
      expect(store.value, isNull);
    });
  });

  group('NotificationPushPrefs', () {
    const all = NotificationPushPrefs(
      plans: true,
      mentionsReplies: true,
      likesReposts: true,
      followers: true,
      messages: true,
    );

    test('withGroup changes one group only', () {
      for (final group in NotificationPrefsGroup.values) {
        final next = all.withGroup(group, false);
        for (final other in NotificationPrefsGroup.values) {
          expect(next.isOn(other), other != group);
        }
      }
    });

    test('groups are listed in the Settings order', () {
      expect(
        [for (final g in NotificationPrefsGroup.values) g.label],
        [
          'Plans',
          'Mentions and replies',
          'Likes and reposts',
          'Followers',
          'Messages',
        ],
      );
    });
  });
}
