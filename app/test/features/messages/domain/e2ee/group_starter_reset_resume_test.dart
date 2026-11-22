import 'dart:async';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart'
    show kCommitRetryWaitMax, kRequestInFlightMargin;
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/e2ee_reset_harness.dart';

// Review m-7: the reset's call rules (amendment 1), its resume and expiry
// (amendment 4) and a later generation passing it (amendment 6), moved
// unchanged from `group_starter_reset_test.dart`.

const _c1 = '11111111111111111111111111111111';
const _me = 'user-a';

void main() {
  // The shared state and helpers (`e2ee_reset_harness.dart`, review m-7).
  registerResetHarness();

  group('the call rules (amendment 1) and timer priority (amendment 2)', () {
    test('a recognised retry of a stored reset still draws both server '
        'caps (the rig models commitCaps)', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      // The second call was recognised as a retry (nothing more stored).
      expect(rig.server.commitAt(_c1, const MlsPair(2, 0)), isNotNull);
      expect(rig.server.current(_c1), const MlsPair(2, 1));
      expect(rig.server.resetDraws[_me], 2);
      expect(rig.server.commitDraws['$_me|$_c1'], 2);
      // At the user's reset cap the server refuses before recognising.
      rig.server.resetCapPerUser = 2;
      await expectLater(
        rig.messaging.commitConversation(
          idempotencyKey: 'k',
          conversationId: _c1,
          builtOn: const MlsPair(1, 0),
          commit: resets().first.commit,
          welcome: resets().first.welcome,
          welcomeDeviceIds: resets().first.welcomeDeviceIds,
          reset: true,
        ),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limitName',
            kLimitResetsDaily,
          ),
        ),
      );
      expect(rig.server.commitDraws['$_me|$_c1'], 3);
      expect(rig.server.resetDraws[_me], 2);
    });

    test('another reset won is not decided while an abandoned reset call '
        'still runs; its end decides', () async {
      await setUpJoined();
      await makeStuck();
      final ended = Completer<void>();
      rig.server.commitScript.add(unknown);
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        final n = rig.server.commitRequests.length;
        if (n == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        } else if (n == 2) {
          // Bob's reset lands between the two calls.
          await bobResets(1);
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      // Kept: the first call may still reach the server.
      expect((await groupAt(2))!.provisional, isTrue);
      expect(rig.server.acks, isEmpty);

      ended.complete();
      await pumpEventQueue();
      expect(rig.scheduled.single.delay, kRequestInFlightMargin);
      // The timer fires after its delay (review I1: a resume inside the
      // wait after the unknown outcome does not even list).
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      expect(rig.server.acks, isNotEmpty);
      expect(resets(), hasLength(2));
    });

    test('a refused resend is dropped only after the margin that follows '
        'the end of an abandoned call', () async {
      await setUpJoined();
      await makeStuck();
      final ended = Completer<void>();
      rig.server.commitScript.addAll([
        unknown,
        (
          error: const FeatureDisabledException('off', feature: 'e2ee_dm'),
          stored: false,
        ),
      ]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);

      ended.complete();
      await pumpEventQueue();
      await runScheduled();
      // The margin counts from the call's end: not passed yet.
      expect((await groupAt(2))!.provisional, isTrue);
      expect(resets(), hasLength(2), reason: 'refused bytes are not resent');
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      expect(await groupAt(2), isNull);
      expect(await groupAt(1), isNotNull);
      expect(resets(), hasLength(2));
    });

    test('review m-5: a refused reset is not even listed while the wait '
        'after its unknown outcome runs', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([
        unknown,
        (
          error: const FeatureDisabledException('off', feature: 'e2ee_dm'),
          stored: false,
        ),
      ]);
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);

      // Held back by the first call's unknown outcome: no listing, and one
      // resume is scheduled for the wait's end (the decision is still due).
      rig.server.calls.clear();
      rig.scheduled.clear();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect((await groupAt(2))!.provisional, isTrue);
      expect(
        [for (final e in rig.scheduled) e.delay],
        [kRequestInFlightMargin],
      );

      // That resume, after the wait: the record decides (not stored, so the
      // group goes).
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      expect(await groupAt(2), isNull);
      expect(resets(), hasLength(2), reason: 'refused bytes are not resent');
    });

    test('a server retry time holds the resend, at most 5 minutes, and the '
        'timer-driven resend runs at live, never at user', () async {
      await setUpJoined(spyBudget: true);
      await makeStuck();
      rig.server.commitScript.add((
        error: const ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(hours: 1),
        ),
        stored: false,
      ));
      await reset();
      expect(resets(), hasLength(1));
      expect(rig.scheduled.single.delay, kCommitRetryWaitMax);
      // A resume before that time sends nothing (nor lists: review I1).
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(1));

      rig.clock.advance(kCommitRetryWaitMax);
      spy!.taken.clear();
      final entry = rig.scheduled.removeAt(0);
      rig.scheduled.clear();
      entry.run();
      await starter.settled(_c1);
      expect(resets(), hasLength(2));
      expect(resets()[0].sameBytes(resets()[1]), isTrue);
      expect(spy!.taken, isNotEmpty);
      expect(spy!.taken, isNot(contains(BudgetPriority.user)));
      expect(spy!.taken, contains(BudgetPriority.live));
      expect((await groupAt(2))!.provisional, isFalse);
      expect((await sync()).commitCallsToday, 2);
    });
  });

  group('resumeProvisional and resets (amendment 4)', () {
    test('a provisional reset older than 24 h is settled from its record at '
        '(g + 1, 0)', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      await rig.restart();
      build();
      listingsFail = false;
      rig.clock.advance(const Duration(hours: 25));
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(resets(), hasLength(2));
    });

    test(
      'an unstored reset older than 24 h expires only on a listing that '
      'started after the margin, never while an abandoned call runs',
      () async {
        await setUpJoined();
        await makeStuck();
        final ended = Completer<void>();
        rig.server.commitScript.addAll([unknown, unknown]);
        rig.server.onCall = (call) async {
          if (call == 'commitConversation' &&
              rig.server.commitRequests.length == 1) {
            rig.server.abandon(
              rig.server.commitRequests.last.key,
              ended.future,
            );
          }
        };
        await reset();
        expect((await groupAt(2))!.provisional, isTrue);
        rig.clock.advance(const Duration(hours: 25));
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect((await groupAt(2))!.provisional, isTrue, reason: 'a call runs');

        ended.complete();
        await pumpEventQueue();
        await runScheduled();
        expect((await groupAt(2))!.provisional, isTrue, reason: 'the margin');
        rig.clock.advance(kRequestInFlightMargin);
        await runScheduled();
        expect(await groupAt(2), isNull);
        expect(await groupAt(1), isNotNull);
        // Never sent again after the expiry; the user may reset again.
        expect(resets(), hasLength(2));
        final s = await state();
        expect(s.phase, ConversationPhase.stuck);
        expect(s.canReset, isTrue);
      },
    );

    test('a young unstored reset is resent with the identical bytes by '
        'resumeProvisional once its wait has passed', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2), reason: 'not before the margin');
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(3));
      expect(resets()[0].sameBytes(resets()[2]), isTrue);
      expect((await groupAt(2))!.provisional, isFalse);
    });

    test('review I1: a stored reset whose settle waits makes no further call '
        'over three resumes', () async {
      await setUpJoined();
      await makeStuck();
      // Both calls are stored (the second a recognised retry); every
      // listing of the first run fails, so the reset stays provisional.
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      var listings = 0;
      var walkFails = false;
      // Only the first listing after the restore works (the record is
      // found as ours); every walk of g that a settle starts is
      // interrupted. Audit M1: once the record was read as ours, no resume
      // lists it again, so each later resume lists only for the walk.
      var recordRead = false;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call != 'listConversationCommits') return;
        listings++;
        if (listingsFail) throw const NetworkException('rig: no listing');
        if (walkFails) {
          if (recordRead) {
            throw const NetworkException('rig: the walk of g is interrupted');
          }
          recordRead = true;
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);
      expect(rig.server.resetDraws[_me], 2);
      expect((await sync()).commitCallsToday, 2);

      listingsFail = false;
      walkFails = true;
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(kRequestInFlightMargin);
        listings = 0;
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect(
          listings,
          greaterThan(0),
          reason: 'resume $i listed (the record, or the walk of g)',
        );
      }
      expect(resets(), hasLength(2), reason: 'an accepted reset needs no call');
      expect(rig.server.resetDraws[_me], 2);
      expect(rig.server.commitDraws['$_me|$_c1'], 2);
      expect((await sync()).commitCallsToday, 2);
      expect((await groupAt(2))!.provisional, isTrue);

      // The next trigger whose walk completes settles it, still with no
      // call.
      walkFails = false;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(resets(), hasLength(2));
    });

    test('review I1: a reset whose record cannot be read is resent at most '
        'once per margin, and not listed while held back', () async {
      await setUpJoined();
      await makeStuck();
      // Every answer is lost (audit M1: an answer would tell the server
      // holds the bytes, and nothing would be resent).
      rig.server.commitScript.addAll([
        lostAnswer,
        lostAnswer,
        lostAnswer,
        lostAnswer,
      ]);
      var listings = 0;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call != 'listConversationCommits') return;
        listings++;
        if (listingsFail) throw const NetworkException('rig: no listing');
      };
      await reset();
      expect(resets(), hasLength(2));

      // Held back by the last unknown outcome: no listing, no call.
      listings = 0;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(listings, 0, reason: 'heldBack is checked before the listing');
      expect(resets(), hasLength(2));

      // Past the wait, every listing still fails: one resend.
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(3));
      // More triggers inside the margin of that resend: no call.
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(const Duration(seconds: 1));
        await starter.resumeProvisional();
        await starter.settled(_c1);
      }
      expect(resets(), hasLength(3));
      expect(rig.server.resetDraws[_me], 3);
      // One margin later: one more.
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(4));
      expect(resets()[0].sameBytes(resets()[3]), isTrue);
      expect((await sync()).commitCallsToday, 4);
      expect((await groupAt(2))!.provisional, isTrue);
    });

    test('audit L2: a repeated page with more stops the record listing at '
        'the first page that does not move forward', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      pb.ListConversationCommitsResponse? page;
      var listings = 0;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') {
          // From here on every listing answers the same page, with more.
          rig.server.rewriteCommits = (real) =>
              page ??= real.deepCopy()..more = true;
          listings = 0;
        }
        if (call == 'listConversationCommits') listings++;
      };
      await reset();
      expect(resets(), hasLength(2));
      expect(page!.commits, isNotEmpty);
      // The first page moves the listing to its last pair; the same page
      // again is no answer: one more listing, not up to the page cap.
      expect(listings, 2);
      expect((await groupAt(2))!.provisional, isTrue);
    });

    test('audit M1: a reset the server answered is never resent while the '
        'listings fail; only its settle is retried', () async {
      await setUpJoined();
      await makeStuck();
      // The call answers (g + 1, 1); every listing after it fails, so the
      // settle's walk of g cannot run and the reset stays provisional.
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect(resets(), hasLength(1));
      expect((await groupAt(2))!.provisional, isTrue);
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(kRequestInFlightMargin);
        await starter.resumeProvisional();
        await starter.settled(_c1);
      }
      expect(resets(), hasLength(1), reason: 'the server holds these bytes');
      expect(rig.server.resetDraws[_me], 1);
      expect((await sync()).commitCallsToday, 1);
      expect((await groupAt(2))!.provisional, isTrue);

      // The next trigger whose walk runs settles it, with no call.
      listingsFail = false;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(resets(), hasLength(1));
    });

    test('audit M1: a listing the local sync budget refuses is not asked: '
        'no decision and no call', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);

      rig.clock.advance(kRequestInFlightMargin);
      rig.syncBudget.pauseUntil(rig.clock.now().add(const Duration(hours: 1)));
      rig.server.calls.clear();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect(resets(), hasLength(2), reason: 'not asked is no answer');
      expect((await groupAt(2))!.provisional, isTrue);
    });
  });

  group('a later generation passes a provisional reset (amendment 6)', () {
    test('a join of a later generation ends the provisional reset it '
        'passed, never leaving it for good', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);
      // Bob reset into 2 without this device, then into 3 with it.
      await bobResets(1, addMe: false);
      await bobResets(2);
      await rig.crypto.processWelcomes();
      expect((await groupAt(3))!.provisional, isFalse);
      expect(await groupAt(2), isNull);
      final st = await state();
      expect(st.phase, isNot(ConversationPhase.provisional));
      expect(st.sendBlock, isNot(SendBlock.provisional));
    });

    /// Review M1: this device's reset into 2 is STORED (both calls landed,
    /// every listing failed, so it is still provisional), and the marks are
    /// already past it, at (3, 0). The join change keeps this state from
    /// arising; it is seeded here so the two defensive ends are pinned. g's
    /// last epoch is marked walked, so neither path walks first.
    Future<void> seedPassedStoredReset() async {
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);
      expect(rig.server.commitAt(_c1, const MlsPair(2, 0)), isNotNull);
      final g1 = (await groupAt(1))!;
      final s = await sync();
      await rig.device.vault.transaction((tx) async {
        await tx.putConversationSync(
          _c1,
          s.copyWith(completedEpochs: [MlsPair(1, g1.epoch)]),
        );
        await tx.setAfterPair(_c1, const MlsPair(3, 0));
      });
      listingsFail = false;
      rig.clock.advance(kRequestInFlightMargin);
    }

    test('review M1: the starter ends a stored reset the marks already '
        'passed (InitSettle.replay), with no call', () async {
      await setUpJoined();
      await makeStuck();
      await seedPassedStoredReset();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(await groupAt(2), isNull, reason: 'never provisional for good');
      expect(resets(), hasLength(2));
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(3, 0),
      );
      expect(
        [for (final l in await lines()) l.line],
        isNot(contains(SystemLine.encryptionReset)),
        reason: 'a replay writes nothing',
      );
    });

    test('review M1: a join discards an own STORED reset of a lower '
        'generation that the marks already passed', () async {
      await setUpJoined();
      await makeStuck();
      await seedPassedStoredReset();
      // A welcome above both marks, of a later generation (its bytes do not
      // matter here: the lower reset is ended before any join).
      rig.server.addWelcome(
        rig.device.deviceIdString,
        _c1,
        const MlsPair(3, 1),
        rigBytes('a welcome of generation 3'),
      );
      await rig.crypto.processWelcomes();
      expect(await groupAt(2), isNull, reason: 'never provisional for good');
      expect(resets(), hasLength(2));
      expect([
        for (final l in await lines()) l.line,
      ], isNot(contains(SystemLine.encryptionReset)));
    });
  });
}
