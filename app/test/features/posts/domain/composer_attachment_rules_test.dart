import 'package:dzeroth/features/posts/domain/composer_attachment_rules.dart';
import 'package:flutter_test/flutter_test.dart';

ComposerAttachmentRules _rules({
  bool flagPolls = true,
  bool engagementOn = true,
  bool flagGif = true,
  bool mediaOn = true,
  bool isReply = false,
  bool isQuote = false,
  bool hasPhotos = false,
  bool hasGif = false,
  bool hasPoll = false,
  bool scheduled = false,
}) => ComposerAttachmentRules(
  flagPolls: flagPolls,
  engagementOn: engagementOn,
  flagGif: flagGif,
  mediaOn: mediaOn,
  isReply: isReply,
  isQuote: isQuote,
  hasPhotos: hasPhotos,
  hasGif: hasGif,
  hasPoll: hasPoll,
  scheduled: scheduled,
);

void main() {
  test('the flag names', () {
    expect(kFeaturePolls, 'polls');
    expect(kFeatureGif, 'gif');
  });

  group('visibility', () {
    test('poll needs polls and engagement', () {
      expect(_rules().showPoll, isTrue);
      expect(_rules(flagPolls: false).showPoll, isFalse);
      expect(_rules(engagementOn: false).showPoll, isFalse);
    });

    test('GIF needs gif and media', () {
      expect(_rules().showGif, isTrue);
      expect(_rules(flagGif: false).showGif, isFalse);
      expect(_rules(mediaOn: false).showGif, isFalse);
    });

    test('a reply or a quote never offers a poll; a quote offers a GIF', () {
      expect(_rules(isReply: true).showPoll, isFalse);
      expect(_rules(isQuote: true).showPoll, isFalse);
      expect(_rules(isQuote: true).showGif, isTrue);
    });
  });

  group('mutual exclusion', () {
    test('nothing attached: everything on', () {
      final r = _rules();
      expect(r.poll, ComposerBlock.none);
      expect(r.gif, ComposerBlock.none);
      expect(r.photo, ComposerBlock.none);
      expect(r.schedule, ComposerBlock.none);
    });

    test('a schedule disables the poll and the GIF, not photos', () {
      final r = _rules(scheduled: true);
      expect(r.poll, ComposerBlock.scheduled);
      expect(r.poll.pollTooltip, "Polls can't be scheduled");
      // SchedulePost refuses GIF media (VALIDATION media_ids, ADR-0029 D10).
      expect(r.gif, ComposerBlock.scheduled);
      expect(r.gif.gifTooltip, "GIFs can't be scheduled");
      expect(r.photo, ComposerBlock.none);
    });

    test('a poll disables photo, GIF and Schedule', () {
      final r = _rules(hasPoll: true);
      expect(r.photo, ComposerBlock.hasPoll);
      expect(r.gif, ComposerBlock.hasPoll);
      expect(r.schedule, ComposerBlock.hasPoll);
      expect(r.schedule.scheduleTooltip, "Polls can't be scheduled");
    });

    test('a GIF disables photos, the poll and Schedule', () {
      final r = _rules(hasGif: true);
      expect(r.photo, ComposerBlock.hasGif);
      expect(r.poll, ComposerBlock.hasGif);
      expect(r.gif, ComposerBlock.hasGif);
      expect(r.gif.gifTooltip, 'One GIF per post');
      expect(r.schedule, ComposerBlock.hasGif);
      expect(r.schedule.scheduleTooltip, "GIFs can't be scheduled");
    });

    test('a poll still wins the Schedule reason over a GIF', () {
      // Never both in practice; the order is fixed so a stale input is stable.
      expect(
        _rules(hasPoll: true, hasGif: true).schedule,
        ComposerBlock.hasPoll,
      );
    });

    test('photos disable the GIF and the poll', () {
      final r = _rules(hasPhotos: true);
      expect(r.gif, ComposerBlock.hasPhotos);
      expect(r.poll, ComposerBlock.hasPhotos);
      expect(r.photo, ComposerBlock.none);
    });

    test(
      'every disabled state has its own reason, the default is the name',
      () {
        expect(ComposerBlock.none.pollTooltip, 'Add poll');
        expect(ComposerBlock.none.gifTooltip, 'Add a GIF');
        expect(ComposerBlock.none.photoTooltip, 'Add photos');
        expect(ComposerBlock.none.scheduleTooltip, 'Schedule post');
        for (final b in ComposerBlock.values.where(
          (b) => b != ComposerBlock.none,
        )) {
          for (final t in [b.pollTooltip, b.gifTooltip, b.photoTooltip]) {
            expect(t, isNotEmpty);
          }
        }
      },
    );
  });
}
