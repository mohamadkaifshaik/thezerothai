import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/widgets/thread_side_boxes.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';
import '../../../support/messages_tablet_fixtures.dart';
import '../../../support/messaging_flow_rig.dart';

// The desktop Chat mock: the conversation inside the shell with the peer's
// side column (card, shared plans, the info menu's actions). Phone and tablet
// keep their pages (the tablet its list beside the thread and the info
// sheet), and the routes are the same at every width.

class _MockBeacons extends Mock implements BeaconsRepository {}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

final _flags = {
  ...kMessagesTabletFlags,
  kFeatureBeacons,
  kFeatureChatSharedPlans,
};

Finder _inColumn(Finder f) =>
    find.descendant(of: find.byType(AppSideColumn), matching: f);

_MockBeacons _beacons({bool shared = true}) {
  final beacons = _MockBeacons();
  when(
    () => beacons.listSharedBeacons(
      peerUserId: any(named: 'peerUserId'),
      limit: any(named: 'limit'),
      pageToken: any(named: 'pageToken'),
    ),
  ).thenAnswer(
    (_) async => BeaconsPage(
      views: shared
          ? [
              beaconView(
                startAt: DateTime.now().add(const Duration(days: 1)),
                title: 'Flat white before work',
              ),
            ]
          : const [],
      nextPageToken: '',
    ),
  );
  return beacons;
}

Future<MessagingFlowRig> _open(
  WidgetTester tester,
  Size size,
  String location, {
  Set<String>? flags,
  BeaconsRepository? beacons,
  common.AuthorSnapshot? draftPeer,
}) async {
  final rig = MessagingFlowRig(server: tabletServer(), flags: flags ?? _flags);
  await rig.pump(
    tester,
    size: size,
    hoisted: true,
    location: draftPeer == null ? location : AppRouter.messagesPath,
    extraProviders: [
      RepositoryProvider<BeaconsRepository>.value(value: beacons ?? _beacons()),
    ],
  );
  if (draftPeer != null) {
    rig.appRouter.router.push(AppRouter.messageDraftPath, extra: draftPeer);
  }
  await tester.pumpAndSettle();
  return rig;
}

void main() {
  final chat = AppRouter.messagePath(inboxId(0));

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final desktop = size.width >= 1200;
    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('Chat: the peer column beside the thread on desktop only', (
        tester,
      ) async {
        await _open(tester, size, chat);
        expect(
          find.byType(ThreadSideBoxes),
          desktop ? findsOneWidget : findsNothing,
        );
        if (desktop) {
          expect(_inColumn(find.text(peerName(0))), findsOneWidget);
          expect(_inColumn(find.text('@peer0')), findsOneWidget);
          expect(_inColumn(find.text('View profile')), findsOneWidget);
          expect(_inColumn(find.text('Mute')), findsOneWidget);
          expect(_inColumn(find.text('Shared plan')), findsOneWidget);
          expect(
            _inColumn(find.text('Flat white before work')),
            findsOneWidget,
          );
          expect(_inColumn(find.text('Block @peer0')), findsOneWidget);
          expect(_inColumn(find.text('Report @peer0')), findsOneWidget);
          expect(_inColumn(find.text('Delete conversation')), findsOneWidget);
          // The rail is the shell's: the thread is in the centre column.
          expect(find.byType(NavigationRail), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('Draft thread: the peer card only', (tester) async {
        await _open(
          tester,
          size,
          chat,
          draftPeer: common.AuthorSnapshot(
            userId: 'u-sam',
            handle: 'sam',
            displayName: 'Sam Rivera',
          ),
        );
        expect(
          find.byType(ThreadSideBoxes),
          desktop ? findsOneWidget : findsNothing,
        );
        if (desktop) {
          expect(_inColumn(find.text('Sam Rivera')), findsOneWidget);
          expect(_inColumn(find.text('View profile')), findsOneWidget);
          expect(_inColumn(find.text('Delete conversation')), findsNothing);
          expect(_inColumn(find.text('Shared plan')), findsNothing);
        }
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('no shared plans: no box', (tester) async {
    await _open(
      tester,
      _sizes['desktop']!,
      chat,
      beacons: _beacons(shared: false),
    );
    expect(find.text('Shared plan'), findsNothing);
    expect(find.text('Shared plans'), findsNothing);
  });

  testWidgets('without chat_shared_plans the list is never asked', (
    tester,
  ) async {
    final beacons = _beacons();
    await _open(
      tester,
      _sizes['desktop']!,
      chat,
      flags: {...kMessagesTabletFlags, kFeatureBeacons},
      beacons: beacons,
    );
    expect(find.text('Shared plan'), findsNothing);
    verifyNever(
      () => beacons.listSharedBeacons(
        peerUserId: any(named: 'peerUserId'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    );
  });

  testWidgets('a failing shared-plans call leaves the box out', (tester) async {
    final beacons = _MockBeacons();
    when(
      () => beacons.listSharedBeacons(
        peerUserId: any(named: 'peerUserId'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const UnknownApiException('nope'));
    await _open(tester, _sizes['desktop']!, chat, beacons: beacons);
    expect(find.byType(ThreadSideBoxes), findsOneWidget);
    expect(find.text('Shared plan'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('View profile is a live button for a peer with a handle', (
    tester,
  ) async {
    await _open(tester, _sizes['desktop']!, chat);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: _inColumn(find.text('View profile')),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('Delete conversation asks first', (tester) async {
    await _open(tester, _sizes['desktop']!, chat);
    await tester.tap(_inColumn(find.text('Delete conversation')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
