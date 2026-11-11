import 'package:dzeroth/features/communities/domain/community_search.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('memberSearchInputOf / memberSearchPrefix (F36)', () {
    final cases = <String, (MemberSearchInput, String?)>{
      '': (MemberSearchInput.blank, null),
      '   ': (MemberSearchInput.blank, null),
      '@': (MemberSearchInput.blank, null),
      'a': (MemberSearchInput.tooShort, null),
      '@a': (MemberSearchInput.tooShort, null),
      'ab': (MemberSearchInput.ready, 'ab'),
      '@Ab_1': (MemberSearchInput.ready, 'ab_1'),
      ' mo ': (MemberSearchInput.ready, 'mo'),
      'abcdefghijklmno': (MemberSearchInput.ready, 'abcdefghijklmno'),
      'abcdefghijklmnop': (MemberSearchInput.tooLong, null),
      '@abcdefghijklmnop': (MemberSearchInput.tooLong, null),
      'abcdefghijklmno.': (MemberSearchInput.invalid, null),
      'a b': (MemberSearchInput.invalid, null),
      'sana.n': (MemberSearchInput.invalid, null),
      '@@ab': (MemberSearchInput.invalid, null),
      '#ab': (MemberSearchInput.invalid, null),
      '.': (MemberSearchInput.invalid, null),
    };
    for (final MapEntry(key: raw, value: (input, prefix)) in cases.entries) {
      test('"$raw" is $input${prefix == null ? '' : ' ($prefix)'}', () {
        expect(memberSearchInputOf(raw), input);
        expect(memberSearchPrefix(raw), prefix);
      });
    }
  });

  group('filterCommunities (F37)', () {
    final list = [
      pb.Community(communityId: '1', name: 'Chess club', description: ''),
      pb.Community(
        communityId: '2',
        name: 'Book club',
        description: 'Novels and CHESS stories',
      ),
      pb.Community(communityId: '3', name: 'Running'),
    ];

    test('a blank query keeps every row, in order', () {
      expect(filterCommunities(list, '  '), same(list));
    });

    test('matches the name or the description, case-insensitive', () {
      expect(
        [for (final c in filterCommunities(list, ' chess ')) c.communityId],
        ['1', '2'],
      );
      expect(
        [for (final c in filterCommunities(list, 'RUN')) c.communityId],
        ['3'],
      );
      expect(filterCommunities(list, 'tennis'), isEmpty);
    });
  });

  group('communitiesMayBeCut', () {
    test('a next page or 50 rows may be cut; fewer with no page is whole', () {
      expect(communitiesMayBeCut(count: 3, hasMore: false), isFalse);
      expect(communitiesMayBeCut(count: 49, hasMore: false), isFalse);
      expect(communitiesMayBeCut(count: 50, hasMore: false), isTrue);
      expect(communitiesMayBeCut(count: 3, hasMore: true), isTrue);
    });
  });
}
