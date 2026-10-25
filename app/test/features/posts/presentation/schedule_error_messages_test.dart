import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/posts/domain/schedule_rules.dart';
import 'package:dzeroth/features/posts/presentation/post_error_messages.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

/// The words for a failed SchedulePost, a failed Cancel/Dismiss, the list
/// banner and the FAILED rows (CMP-D6, ADR-0021 D4).
void main() {
  group('scheduleErrorMessage', () {
    test('the two LIMIT_REACHED names and the daily quota', () {
      expect(
        scheduleErrorMessage(
          const LimitReachedException('x', quota: 'scheduled_pending'),
        ),
        'You have too many scheduled posts. Cancel one first.',
      );
      expect(
        scheduleErrorMessage(
          const LimitReachedException('x', quota: 'scheduled_window'),
        ),
        'Too many posts are scheduled around that time. Pick another time.',
      );
      expect(
        scheduleErrorMessage(
          const QuotaExceededException('x', quota: 'schedules'),
        ),
        "You've reached today's limit for scheduling posts. It resets "
        'tomorrow.',
      );
    });

    test('an unnamed limit is still friendly', () {
      expect(
        scheduleErrorMessage(const LimitReachedException('x')),
        "You can't schedule more posts right now. Try again later.",
      );
    });

    test('a refused time, an unavailable photo, the flag', () {
      expect(
        scheduleErrorMessage(
          const ValidationException('x', field: 'publish_at'),
        ),
        kScheduleRejectedMessage,
      );
      expect(
        scheduleErrorMessage(const MediaNotReadyException('x')),
        'One of your photos is no longer available. Remove it and try again.',
      );
      expect(
        scheduleErrorMessage(
          const FeatureDisabledException('x', feature: 'scheduled_posts'),
        ),
        "Scheduling isn't available right now.",
      );
      expect(
        scheduleErrorMessage(
          const FeatureDisabledException('x', feature: 'media'),
        ),
        contains("Photos can't be added"),
      );
    });

    test('the reply audience refusal says the post will be open to everyone, '
        'not that scheduling is off', () {
      expect(
        scheduleErrorMessage(
          const FeatureDisabledException('x', feature: 'reply_audience'),
        ),
        "Choosing who can reply isn't available right now. Your post will be "
        'open to everyone.',
      );
    });

    test('a lost response is never reported as "not scheduled"', () {
      final message = scheduleErrorMessage(const NetworkException('x'));
      expect(
        message,
        "Couldn't confirm your post was scheduled. Tap Schedule to try again, "
        'or check Scheduled posts.',
      );
      expect(message, isNot(contains('not scheduled')));
    });

    test('other failures use scheduling wording or the shared text', () {
      expect(
        scheduleErrorMessage(const DegradedModeException('x')),
        contains('scheduling is paused'),
      );
      expect(
        scheduleErrorMessage(const ValidationException('x')),
        "This post can't be scheduled. Check the text and try again.",
      );
      expect(
        scheduleErrorMessage(const UnknownApiException('stack trace')),
        allOf(contains('schedule'), isNot(contains('stack trace'))),
      );
      expect(
        scheduleErrorMessage(const EmailNotVerifiedException('x')),
        contains('verify your email'),
      );
      expect(
        scheduleErrorMessage(const QuotaExceededException('x')),
        contains("today's limit"),
      );
    });
  });

  group('scheduledFailureMessage', () {
    final expected = {
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_MEDIA_UNAVAILABLE:
          'An image is no longer available.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_QUOTA_EXCEEDED:
          'You reached the daily post limit.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_ACCOUNT_RESTRICTED:
          'Your account could not post.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_INVALID_CONTENT:
          'The post no longer meets the rules.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_EXPIRED:
          'It could not be sent in time.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_INTERNAL:
          'Something went wrong.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_UNSUPPORTED:
          'Something went wrong.',
      ScheduledPostFailure.SCHEDULED_POST_FAILURE_UNSPECIFIED:
          'Something went wrong.',
    };
    for (final entry in expected.entries) {
      test('${entry.key.name} -> ${entry.value}', () {
        expect(scheduledFailureMessage(entry.key), entry.value);
      });
    }

    test('every known failure has a sentence', () {
      for (final failure in ScheduledPostFailure.values) {
        expect(scheduledFailureMessage(failure), isNotEmpty);
      }
    });
  });

  group('cancel and list wording', () {
    test('Cancel and Dismiss failures', () {
      expect(
        cancelScheduledErrorMessage(const NetworkException('x')),
        'No connection. Check your network and try again.',
      );
      expect(
        cancelScheduledErrorMessage(const NetworkException('x'), dismiss: true),
        'No connection. Check your network and try again.',
      );
      expect(
        cancelScheduledErrorMessage(const FeatureDisabledException('x')),
        "Scheduled posts aren't available right now.",
      );
      expect(
        cancelScheduledErrorMessage(const UnknownApiException('x')),
        "Couldn't cancel that post. Please try again.",
      );
      expect(
        cancelScheduledErrorMessage(
          const UnknownApiException('x'),
          dismiss: true,
        ),
        "Couldn't dismiss that post. Please try again.",
      );
      expect(
        cancelScheduledErrorMessage(const RateLimitedException('x')),
        contains('too fast'),
      );
    });

    test('the banner over the list', () {
      expect(
        scheduledListNoticeMessage(const NetworkException('x')),
        "You're offline. Showing the scheduled posts already loaded.",
      );
      expect(
        scheduledListNoticeMessage(const UnknownApiException('x')),
        "Couldn't refresh your scheduled posts.",
      );
      expect(
        scheduledListNoticeMessage(const RateLimitedException('x')),
        contains('too fast'),
      );
    });
  });
}
