import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/text_size_cubit.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/notifications/data/notifications_repository.dart';
import 'package:dzeroth/features/notifications/domain/notification_prefs.dart';
import 'package:dzeroth/features/notifications/domain/notifications_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/settings/data/own_privacy_store.dart';
import 'package:dzeroth/features/settings/domain/message_privacy.dart';
import 'package:dzeroth/features/settings/presentation/message_settings_messages.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/features/settings/presentation/widgets/settings_choice_row.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as posts;
import 'package:dzeroth/shared/widgets/primitives/app_chip.dart';
import 'package:dzeroth/shared/widgets/primitives/settings_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/settings_tablet_rig.dart';

class _MockNotifications extends Mock implements NotificationsRepository {}

class _MockPosts extends Mock implements PostsRepository {}

class _MemoryTextSize implements TextSizeStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

const _allWidths = [
  360.0,
  599.0,
  600.0,
  839.0,
  840.0,
  1024.0,
  1199.0,
  1200.0,
  1440.0,
];

/// Phone, desktop and the legacy layout: the flat list (no categories).
bool _flat(double width) => width < 600 || width >= 1200;

const _prefsFlags = {kFeatureNotifications, kFeatureNotificationPrefs};
const _privacyFlags = {
  kFeatureMessaging,
  kFeatureReadReceipts,
  kFeatureDmPolicy,
};

const _server = NotificationPushPrefs(
  plans: true,
  mentionsReplies: true,
  likesReposts: false,
  followers: true,
  messages: true,
);

OwnPrivacyStore _store({
  bool receipts = false,
  identity.DmPolicy policy = identity.DmPolicy.DM_POLICY_UNSPECIFIED,
}) => OwnPrivacyStore()
  ..record(
    identity.Profile(
      userId: 'u-alice',
      readReceipts: receipts,
      dmPolicy: policy,
    ),
  );

List<String> _titles(WidgetTester tester) => [
  for (final row in tester.widgetList(
    find.byWidgetPredicate((w) => w is SettingsRow || w is SettingsChoiceRow),
  ))
    row is SettingsRow ? row.title : (row as SettingsChoiceRow).title,
];

Finder _row(String title) => find.byWidgetPredicate(
  (w) =>
      (w is SettingsRow && w.title == title) ||
      (w is SettingsChoiceRow && w.title == title),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late _MockNotifications notifications;
  late _MockPosts postsRepo;

  setUpAll(() {
    registerFallbackValue(_server);
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  setUp(() {
    notifications = _MockNotifications();
    when(() => notifications.getPushPrefs()).thenAnswer((_) async => _server);
    postsRepo = _MockPosts();
  });

  void stubUpdate(
    SettingsTabletRig rig,
    Future<identity.Profile> Function(Invocation) answer,
  ) {
    when(
      () => rig.identityRepository.updateProfile(
        idempotencyKey: any(named: 'idempotencyKey'),
        readReceipts: any(named: 'readReceipts'),
        dmPolicy: any(named: 'dmPolicy'),
      ),
    ).thenAnswer(answer);
  }

  group('F6 Notifications (notifications + notification_prefs)', () {
    for (final width in _allWidths) {
      for (final (label, extra, shown) in [
        ('both flags', _prefsFlags, true),
        ('notifications only', {kFeatureNotifications}, false),
        ('notification_prefs only', {kFeatureNotificationPrefs}, false),
      ]) {
        testWidgets('$label at ${width.toInt()}', (tester) async {
          final rig = SettingsTabletRig();
          await rig.pump(
            tester,
            width: width,
            height: 2000,
            flags: {...kSettingsTabletFlags, ...extra},
            notifications: notifications,
          );
          expect(_row('Notifications'), shown ? findsOneWidget : findsNothing);
          if (shown) {
            final row = tester.widget<SettingsRow>(_row('Notifications'));
            // The flat row and the tablet category say the same.
            expect(row.subtitle, 'Mentions, followers');
          }
          // Opening Settings sends nothing; the page loads its own.
          verifyNever(() => notifications.getPushPrefs());
        });
      }
    }

    testWidgets('the subtitle names Plans with beacons on', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        height: 2000,
        flags: {...kSettingsTabletFlags, ..._prefsFlags, kFeatureBeacons},
        notifications: notifications,
      );
      expect(
        tester.widget<SettingsRow>(_row('Notifications')).subtitle,
        'Plans, mentions, followers',
      );
    });

    testWidgets('phone: the row opens the page with the server values', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        height: 2000,
        flags: {
          ...kSettingsTabletFlags,
          ..._prefsFlags,
          kFeatureMessaging,
          kFeatureBeacons,
        },
        notifications: notifications,
      );
      await _tap(tester, _row('Notifications'));
      expect(rig.uri.path, AppRouter.notificationSettingsPath);
      expect(find.text('Notification settings'), findsOneWidget);
      final switches = {
        for (final row in tester.widgetList<SettingsRow>(
          find.byType(SettingsRow),
        ))
          row.title: row.toggled,
      };
      expect(switches, {
        'Plans': true,
        'Mentions and replies': true,
        'Likes and reposts': false,
        'Followers': true,
        'Messages': true,
      });
      verify(() => notifications.getPushPrefs()).called(1);
    });

    for (final width in [600.0, 839.0, 840.0, 1024.0, 1199.0]) {
      testWidgets(
        'tablet ${width.toInt()}: the category page is the switches',
        (tester) async {
          final rig = SettingsTabletRig();
          await rig.pump(
            tester,
            width: width,
            height: 1400,
            flags: {...kSettingsTabletFlags, ..._prefsFlags},
            notifications: notifications,
          );
          final category = find.byWidgetPredicate(
            (w) => w is SettingsRow && w.title == 'Notifications',
          );
          // Your account, Privacy & safety, Notifications, Display, ...
          expect(category, findsOneWidget);
          expect(
            tester.widget<SettingsRow>(category).subtitle,
            'Mentions, followers',
          );
          await _tap(tester, category);
          expect(rig.uri.toString(), '/settings?c=notifications');
          // Plans needs beacons, Messages needs messaging: hidden here.
          expect(
            [
              for (final row in tester.widgetList<SettingsRow>(
                find.descendant(
                  of: find.byType(SettingsScreen),
                  matching: find.byType(SettingsRow),
                ),
              ))
                row.title,
            ],
            ['Mentions and replies', 'Likes and reposts', 'Followers'],
          );
        },
      );
    }

    testWidgets('loading shows a placeholder of the same shape, no switch', (
      tester,
    ) async {
      final pending = Completer<NotificationPushPrefs>();
      when(() => notifications.getPushPrefs())
          .thenAnswer((_) => pending.future);
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        location: AppRouter.notificationSettingsPath,
        flags: {...kSettingsTabletFlags, ..._prefsFlags},
        notifications: notifications,
      );
      expect(
        find.bySemanticsLabel('Loading notification settings'),
        findsOneWidget,
      );
      expect(find.byType(Switch), findsNothing);
      pending.complete(_server);
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNWidgets(3));
    });

    testWidgets('a load failure shows the error and Retry loads again', (
      tester,
    ) async {
      var calls = 0;
      when(() => notifications.getPushPrefs()).thenAnswer((_) async {
        if (calls++ == 0) throw const NetworkException('offline');
        return _server;
      });
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        location: AppRouter.notificationSettingsPath,
        flags: {...kSettingsTabletFlags, ..._prefsFlags},
        notifications: notifications,
      );
      expect(find.byType(Switch), findsNothing);
      await _tap(tester, find.text('Retry'));
      expect(find.byType(Switch), findsNWidgets(3));
    });

    testWidgets('a switch shows the server value while saving and after a '
        'failure', (tester) async {
      final pending = Completer<NotificationPushPrefs>();
      when(
        () => notifications.updatePushPrefs(
          idempotencyKey: any(named: 'idempotencyKey'),
          prefs: any(named: 'prefs'),
        ),
      ).thenAnswer((_) => pending.future);
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        location: AppRouter.notificationSettingsPath,
        flags: {...kSettingsTabletFlags, ..._prefsFlags},
        notifications: notifications,
      );
      SettingsRow followers() => tester.widget<SettingsRow>(_row('Followers'));
      await tester.tap(_row('Followers'));
      await tester.pump();
      // Still the server's ON, and every switch waits.
      expect(followers().toggled, isTrue);
      expect(followers().onTap, isNull);
      expect(
        tester.widget<SettingsRow>(_row('Mentions and replies')).onTap,
        isNull,
      );

      pending.completeError(const NetworkException('offline'));
      await tester.pumpAndSettle();
      expect(followers().toggled, isTrue);
      expect(followers().onTap, isNotNull);
      expect(find.textContaining('No connection'), findsOneWidget);
      final sent =
          verify(
                () => notifications.updatePushPrefs(
                  idempotencyKey: any(named: 'idempotencyKey'),
                  prefs: captureAny(named: 'prefs'),
                ),
              ).captured.single
              as NotificationPushPrefs;
      // Every group sent, from the server's values, one changed.
      expect(sent, _server.withGroup(NotificationPrefsGroup.followers, false));
    });

    testWidgets('typed without notification_prefs: "not available", nothing '
        'sent (the app router also sends it to Settings)', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        location: AppRouter.notificationSettingsPath,
        flags: {...kSettingsTabletFlags, kFeatureNotifications},
        notifications: notifications,
      );
      expect(
        find.text("Notification settings aren't available"),
        findsOneWidget,
      );
      verifyNever(() => notifications.getPushPrefs());
    });

    testWidgets('FEATURE_DISABLED on load is "not available" and refreshes the '
        'flags', (tester) async {
      when(() => notifications.getPushPrefs())
          .thenThrow(const FeatureDisabledException('off'));
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        location: AppRouter.notificationSettingsPath,
        flags: {...kSettingsTabletFlags, ..._prefsFlags},
        notifications: notifications,
      );
      expect(
        find.text("Notification settings aren't available"),
        findsOneWidget,
      );
      verify(() => rig.onboarding.add(const OnboardingRefreshRequested()))
          .called(1);
    });
  });

  group('F3 read receipts and F9 who can message', () {
    for (final width in _allWidths) {
      testWidgets('flags on, server values known: both rows at '
          '${width.toInt()}', (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 2000,
          location: _flat(width) ? '/settings' : '/settings?c=privacy',
          flags: {...kSettingsTabletFlags, ..._privacyFlags},
          ownPrivacy: _store(
            policy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY,
          ),
        );
        final titles = _titles(tester);
        final i = titles.indexOf(kMessageSettingsTitle);
        expect(i, greaterThan(titles.indexOf('Muted accounts')));
        expect(titles[i + 1], kReadReceiptsTitle);
        expect(
          tester.widget<SettingsRow>(_row(kMessageSettingsTitle)).subtitle,
          'People you follow',
        );
        expect(
          tester.widget<SettingsRow>(_row(kReadReceiptsTitle)).toggled,
          isFalse,
        );
      });
    }

    for (final (label, flags, store, receipts, who) in [
      ('no server value yet', _privacyFlags, null, false, false),
      ('flags off, defaults', {kFeatureMessaging}, _store(), false, false),
      (
        'flags off, receipts on (undo rule)',
        {kFeatureMessaging},
        _store(receipts: true),
        true,
        false,
      ),
      (
        'flags off, People you follow (undo rule)',
        <String>{},
        _store(policy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY),
        false,
        true,
      ),
      (
        'flags on, messaging off',
        {kFeatureReadReceipts, kFeatureDmPolicy},
        _store(),
        false,
        false,
      ),
      (
        'read_receipts only',
        {kFeatureMessaging, kFeatureReadReceipts},
        _store(),
        true,
        false,
      ),
      (
        'dm_policy only',
        {kFeatureMessaging, kFeatureDmPolicy},
        _store(),
        false,
        true,
      ),
    ]) {
      testWidgets(label, (tester) async {
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: 360,
          height: 2000,
          flags: {...kSettingsTabletFlags, ...flags},
          ownPrivacy: store ?? OwnPrivacyStore(),
        );
        expect(
          _row(kReadReceiptsTitle),
          receipts ? findsOneWidget : findsNothing,
        );
        expect(
          _row(kMessageSettingsTitle),
          who ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets('read receipts: never shown on before the server says so', (
      tester,
    ) async {
      final pending = Completer<identity.Profile>();
      final rig = SettingsTabletRig();
      stubUpdate(rig, (_) => pending.future);
      final store = _store();
      await rig.pump(
        tester,
        width: 360,
        height: 2000,
        flags: {...kSettingsTabletFlags, ..._privacyFlags},
        ownPrivacy: store,
      );
      SettingsRow row() => tester.widget<SettingsRow>(_row(kReadReceiptsTitle));
      await tester.ensureVisible(_row(kReadReceiptsTitle));
      await tester.pumpAndSettle();
      await tester.tap(_row(kReadReceiptsTitle));
      await tester.pump();
      expect(row().toggled, isFalse);
      expect(row().onTap, isNull, reason: 'disabled while saving');

      pending.complete(identity.Profile(userId: 'u-alice', readReceipts: true));
      await tester.pumpAndSettle();
      expect(row().toggled, isTrue);
      expect(store.value?.readReceipts, isTrue);
      verify(
        () => rig.identityRepository.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          readReceipts: true,
        ),
      ).called(1);
      verify(
        () => rig.onboarding.add(any(that: isA<OnboardingProfileUpdated>())),
      ).called(1);
    });

    testWidgets('read receipts: a failure reverts to the server value with '
        'a snackbar', (tester) async {
      final rig = SettingsTabletRig();
      stubUpdate(rig, (_) async => throw const NetworkException('offline'));
      await rig.pump(
        tester,
        width: 360,
        height: 2000,
        flags: {...kSettingsTabletFlags, ..._privacyFlags},
        ownPrivacy: _store(receipts: true),
      );
      await _tap(tester, _row(kReadReceiptsTitle));
      expect(
        tester.widget<SettingsRow>(_row(kReadReceiptsTitle)).toggled,
        isTrue,
      );
      expect(find.textContaining('No connection'), findsOneWidget);
    });

    testWidgets('read receipts: FEATURE_DISABLED hides the switch and '
        'refreshes the flags', (tester) async {
      final rig = SettingsTabletRig();
      stubUpdate(
        rig,
        (_) async => throw const FeatureDisabledException(
          'off',
          feature: kFeatureReadReceipts,
        ),
      );
      await rig.pump(
        tester,
        width: 360,
        height: 2000,
        flags: {...kSettingsTabletFlags, ..._privacyFlags},
        ownPrivacy: _store(),
      );
      await _tap(tester, _row(kReadReceiptsTitle));
      expect(_row(kReadReceiptsTitle), findsNothing);
      expect(
        find.text("This setting isn't available right now."),
        findsOneWidget,
      );
      verify(() => rig.onboarding.add(const OnboardingRefreshRequested()))
          .called(1);
    });

    testWidgets('Message settings: People you follow is saved, Everyone '
        'stays selected until the server answers', (tester) async {
      final pending = Completer<identity.Profile>();
      final rig = SettingsTabletRig();
      stubUpdate(rig, (_) => pending.future);
      await rig.pump(
        tester,
        width: 360,
        height: 2000,
        flags: {...kSettingsTabletFlags, ..._privacyFlags},
        ownPrivacy: _store(),
      );
      await _tap(tester, _row(kMessageSettingsTitle));
      expect(rig.uri.path, AppRouter.messageSettingsPath);
      AppFilterPill pill(String label) => tester.widget<AppFilterPill>(
        find.widgetWithText(AppFilterPill, label),
      );
      expect(pill('Everyone').selected, isTrue);
      expect(_row(kReadReceiptsTitle), findsOneWidget);

      await tester.tap(find.widgetWithText(AppFilterPill, 'People you follow'));
      await tester.pump();
      expect(pill('Everyone').selected, isTrue);
      expect(pill('People you follow').selected, isFalse);
      expect(pill('Everyone').onPressed, isNull);

      pending.complete(
        identity.Profile(
          userId: 'u-alice',
          dmPolicy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY,
        ),
      );
      await tester.pumpAndSettle();
      expect(pill('People you follow').selected, isTrue);
      verify(
        () => rig.identityRepository.updateProfile(
          idempotencyKey: any(named: 'idempotencyKey'),
          dmPolicy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY,
        ),
      ).called(1);
    });

    testWidgets('Message settings with dm_policy off offers only the way '
        'back to Everyone', (tester) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 360,
        location: AppRouter.messageSettingsPath,
        flags: {...kSettingsTabletFlags, kFeatureMessaging},
        ownPrivacy: _store(policy: identity.DmPolicy.DM_POLICY_FOLLOWING_ONLY),
      );
      expect(find.byType(AppFilterPill), findsNWidgets(2));
      expect(_row(kReadReceiptsTitle), findsNothing);

      final rig2 = SettingsTabletRig();
      await rig2.pump(
        tester,
        width: 360,
        location: AppRouter.messageSettingsPath,
        flags: {...kSettingsTabletFlags, kFeatureMessaging},
        ownPrivacy: _store(),
      );
      expect(find.byType(AppFilterPill), findsNothing);
      expect(find.text(kMessageSettingsUnavailableTitle), findsOneWidget);
    });

    testWidgets('tablet band B: Message settings is a Privacy & safety leaf', (
      tester,
    ) async {
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1024,
        location: '/settings?c=privacy',
        flags: {...kSettingsTabletFlags, ..._privacyFlags},
        ownPrivacy: _store(),
      );
      await _tap(tester, inSettingsPage(_row(kMessageSettingsTitle)));
      expect(rig.uri.path, AppRouter.messageSettingsPath);
      final pane = tester.widgetList<SettingsRow>(
        inCategoriesPane(find.byType(SettingsRow)),
      );
      expect(
        [
          for (final r in pane)
            if (r.selected) r.title,
        ],
        ['Privacy & safety'],
      );
    });
  });

  group('F7 text size', () {
    for (final width in _allWidths) {
      testWidgets('next to Appearance at ${width.toInt()}, applies at once', (
        tester,
      ) async {
        final store = _MemoryTextSize();
        final cubit = TextSizeCubit(store);
        addTearDown(cubit.close);
        final rig = SettingsTabletRig();
        await rig.pump(
          tester,
          width: width,
          height: 2400,
          location: _flat(width) ? '/settings' : '/settings?c=display',
          textSize: cubit,
        );
        final titles = _titles(tester);
        expect(titles.indexOf('Text size'), titles.indexOf('Appearance') + 1);
        await _tap(tester, find.widgetWithText(AppFilterPill, '130%'));
        expect(cubit.state, AppTextSize.larger);
        expect(store.value, 'larger');
        final scaler = MediaQuery.textScalerOf(
          tester.element(find.text('Text size').first),
        );
        expect(scaler.scale(10), closeTo(13, 1e-9));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the display summary names text size', (tester) async {
      final cubit = TextSizeCubit(_MemoryTextSize());
      addTearDown(cubit.close);
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1024, textSize: cubit);
      expect(
        tester.widget<SettingsRow>(inCategoriesPane(_row('Display'))).subtitle,
        'Appearance, text size',
      );
    });
  });

  group('F33 posts waiting', () {
    posts.ScheduledPost item(posts.ScheduledPostStatus status) =>
        posts.ScheduledPost(status: status);

    for (final (label, items, next, subtitle) in [
      (
        'pending only, not failed',
        [
          item(posts.ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING),
          item(posts.ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED),
          item(posts.ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING),
        ],
        '',
        '2 posts waiting',
      ),
      (
        'one',
        [item(posts.ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING)],
        '',
        '1 post waiting',
      ),
      (
        'more pages: a lower bound',
        [item(posts.ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING)],
        'next',
        '1+ posts waiting',
      ),
      ('none: nothing drawn', <posts.ScheduledPost>[], '', null),
    ]) {
      testWidgets(label, (tester) async {
        when(
          () => postsRepo.listScheduledPosts(
            pageSize: any(named: 'pageSize'),
            pageToken: any(named: 'pageToken'),
          ),
        ).thenAnswer(
          (_) async => posts.ListScheduledPostsResponse(
            scheduledPosts: items,
            nextPageToken: next,
          ),
        );
        final rig = SettingsTabletRig();
        await rig.pump(tester, width: 360, height: 2000, posts: postsRepo);
        expect(
          tester.widget<SettingsRow>(_row('Scheduled posts')).subtitle,
          subtitle,
        );
        verify(() => postsRepo.listScheduledPosts(pageSize: 20)).called(1);
      });
    }

    testWidgets('a failure draws no subtitle and no message', (tester) async {
      when(
        () => postsRepo.listScheduledPosts(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenThrow(const NetworkException('offline'));
      final rig = SettingsTabletRig();
      await rig.pump(tester, width: 1024, posts: postsRepo);
      expect(
        tester
            .widget<SettingsRow>(inCategoriesPane(_row('Scheduled posts')))
            .subtitle,
        isNull,
      );
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('band B: one call for the pane and the detail', (tester) async {
      when(
        () => postsRepo.listScheduledPosts(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).thenAnswer((_) async => posts.ListScheduledPostsResponse());
      final rig = SettingsTabletRig();
      await rig.pump(
        tester,
        width: 1024,
        location: '/settings?c=account',
        posts: postsRepo,
      );
      verify(
        () => postsRepo.listScheduledPosts(
          pageSize: any(named: 'pageSize'),
          pageToken: any(named: 'pageToken'),
        ),
      ).called(1);
    });
  });

  group('every R4 row on: no overflow, 48 dp rows, RTL', () {
    for (final (width, height) in [
      (360.0, 2400.0),
      (600.0, 1600.0),
      (840.0, 1600.0),
      (1024.0, 1400.0),
      (1440.0, 1400.0),
    ]) {
      for (final rtl in [false, true]) {
        testWidgets('${width.toInt()} x2.0${rtl ? ' RTL' : ''}', (
          tester,
        ) async {
          final cubit = TextSizeCubit(_MemoryTextSize());
          addTearDown(cubit.close);
          final rig = SettingsTabletRig();
          await rig.pump(
            tester,
            width: width,
            height: height,
            textScale: 2,
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
            location: _flat(width) ? '/settings' : '/settings?c=privacy',
            flags: {...kSettingsTabletFlags, ..._prefsFlags, ..._privacyFlags},
            ownPrivacy: _store(),
            textSize: cubit,
            notifications: notifications,
          );
          expect(tester.takeException(), isNull);
          for (final row in tester.widgetList(find.byType(SettingsRow))) {
            expect(
              tester.getSize(find.byWidget(row)).height,
              greaterThanOrEqualTo(48),
            );
          }
          // The pills wrap rather than clip: each label is whole.
          for (final pill in tester.widgetList<AppFilterPill>(
            find.byType(AppFilterPill),
          )) {
            final text = find.descendant(
              of: find.byWidget(pill),
              matching: find.text(pill.label),
            );
            final paragraph = tester.renderObject<RenderParagraph>(text);
            expect(paragraph.didExceedMaxLines, isFalse, reason: pill.label);
          }
        });
      }
    }
  });
}
