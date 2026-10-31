import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/domain/poll_rules.dart';
import 'package:dzeroth/features/posts/domain/post_text_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shared fixture testdata/poll_rules.json (ADR-0029 D1)', () {
    final json = jsonDecode(
      File('../testdata/poll_rules.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final limits = json['limits'] as Map<String, dynamic>;
    final cases = (json['cases'] as List).cast<Map<String, dynamic>>();

    test('the limits are the constants the client uses', () {
      expect(limits['max_choices'], kPollMaxChoices);
      expect(limits['choice_max_codepoints'], kPollChoiceMaxCodePoints);
      expect(limits['min_duration_minutes'], kPollMinMinutes);
      expect(limits['max_duration_minutes'], kPollMaxMinutes);
    });

    test('runs every row: valid with the stored labels, or refused', () {
      var ran = 0;
      for (final row in cases) {
        final choices = (row['choices'] as List).cast<String>();
        final minutes = row['duration_minutes'] as int;
        final reason = 'row "${row['name']}"';
        final analysis = analyzePoll(
          DraftPoll(choices: choices, durationMinutes: minutes),
        );
        if (row['valid'] == true) {
          expect(analysis.valid, isTrue, reason: reason);
          expect(
            analysis.stored,
            (row['stored'] as List).cast<String>(),
            reason: reason,
          );
        } else {
          expect(analysis.valid, isFalse, reason: reason);
        }
        ran++;
      }
      expect(ran, cases.length);
      expect(ran, 27);
    });
  });

  group('one choice', () {
    PollChoiceCheck check(String raw, [String other = 'other']) =>
        analyzePoll(DraftPoll(choices: [other, raw], durationMinutes: 60))
            .choices[1];

    test('counts code points after normalising, an emoji is one', () {
      expect(check('  \u{1F600}\u{1F600}  ').codePoints, 2);
      expect(check('é').codePoints, 1);
    });

    test('26 code points is too long, 25 is not', () {
      expect(check('a' * 25).tooLong, isFalse);
      expect(check('a' * 26).tooLong, isTrue);
      expect(check('a' * 26).codePoints, 26);
    });

    test('blank and unsupported characters are told apart', () {
      expect(check('   ').blank, isTrue);
      expect(check('a\nb').forbidden, isTrue);
      expect(check('a${String.fromCharCode(0x202E)}b').forbidden, isTrue);
      expect(check('fine').ok, isTrue);
    });

    test('only the LATER one of two equal choices is the duplicate', () {
      final a = analyzePoll(
        const DraftPoll(choices: ['Yes', 'yes'], durationMinutes: 60),
      );
      expect(a.choices[0].duplicate, isFalse);
      expect(a.choices[1].duplicate, isTrue);
      expect(a.valid, isFalse);
    });

    test('an empty row makes the poll invalid but is not a duplicate', () {
      final a = analyzePoll(
        const DraftPoll(choices: ['Yes', ''], durationMinutes: 60),
      );
      expect(a.valid, isFalse);
      expect(a.choices[1].blank, isTrue);
      expect(a.choices[1].duplicate, isFalse);
    });
  });

  group('normalizeLabel', () {
    test('tab becomes a space, NFC, trims the invisible set', () {
      expect(normalizeLabel('\tNo​').text, 'No');
      expect(normalizeLabel('é').text, 'é');
      expect(normalizeLabel('a\tb').text, 'a b');
    });
  });

  group('length', () {
    test('cuts total minutes into days, hours and minutes and back', () {
      const total = 2 * 1440 + 3 * 60 + 7;
      final l = PollLength.fromMinutes(total);
      expect((l.days, l.hours, l.minutes), (2, 3, 7));
      expect(l.totalMinutes, total);
    });

    test('is said in words with singulars', () {
      expect(pollLengthText(1440), '1 day, 0 hours, 0 minutes');
      expect(pollLengthText(61), '0 days, 1 hour, 1 minute');
    });
  });
}
