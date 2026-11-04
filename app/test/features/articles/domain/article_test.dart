import 'dart:convert';

import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:flutter_test/flutter_test.dart';

ArticleBlock paragraph(String text) => ArticleBlock(
  kind: ArticleBlockKind.paragraph,
  runs: [ArticleTextRun(text: text)],
);

void main() {
  test('JSON preserves formatted runs, images, cover and revision', () {
    final draft = ArticleDraft(
      id: 'draft-1',
      authorId: 'alice',
      title: 'A title',
      revision: 3,
      coverMediaId: 'cover',
      blocks: [
        ArticleBlock(
          kind: ArticleBlockKind.heading1,
          runs: [
            ArticleTextRun(
              text: 'Hello',
              marks: [ArticleMark.bold, ArticleMark.italic],
              link: 'https://example.com/path',
            ),
          ],
        ),
        paragraph('World'),
        ArticleBlock(
          kind: ArticleBlockKind.image,
          mediaId: 'image',
          altText: 'A tree',
        ),
        ArticleBlock(kind: ArticleBlockKind.divider),
      ],
    );
    final copy = ArticleDraft.fromJson(jsonDecode(jsonEncode(draft.toJson())));
    expect(copy.toJson(), draft.toJson());
    expect(copy.publishErrors, isEmpty);
    expect(copy.plainText, 'Hello\nWorld');
    expect(copy.wordCount, 2);
  });

  test('draft deeply copies caller collections', () {
    final marks = <ArticleMark>[ArticleMark.bold];
    final runs = [ArticleTextRun(text: 'body', marks: marks)];
    final blocks = [ArticleBlock(kind: ArticleBlockKind.paragraph, runs: runs)];
    final draft = ArticleDraft(id: '1', authorId: 'a', blocks: blocks);
    marks.clear();
    runs.clear();
    blocks.clear();
    expect(draft.blocks.single.runs.single.marks, {ArticleMark.bold});
    expect(() => draft.blocks.clear(), throwsUnsupportedError);
    expect(() => draft.blocks.single.runs.clear(), throwsUnsupportedError);
    expect(
      () => draft.blocks.single.runs.single.marks.clear(),
      throwsUnsupportedError,
    );
  });

  test('revision guards stale edits and cover removal is explicit', () {
    final original = ArticleDraft(id: '1', authorId: 'a', coverMediaId: 'm');
    final edited = original.revise(
      expectedRevision: 0,
      title: 'new',
      removeCover: true,
    );
    expect(edited.revision, 1);
    expect(edited.coverMediaId, isNull);
    expect(original.coverMediaId, 'm');
    expect(() => edited.revise(expectedRevision: 0), throwsStateError);
    expect(
      () => original.revise(
        expectedRevision: 0,
        coverMediaId: 'x',
        removeCover: true,
      ),
      throwsArgumentError,
    );
  });

  test('publish validates empty, excessive and control-containing text', () {
    expect(ArticleDraft(id: '1', authorId: 'a').publishErrors, [
      'title',
      'body',
    ]);
    expect(
      ArticleDraft(
        id: '1',
        authorId: 'a',
        title: '😀' * 100,
        blocks: [paragraph('ok')],
      ).publishErrors,
      isEmpty,
    );
    expect(
      ArticleDraft(
        id: '1',
        authorId: 'a',
        title: '😀' * 101,
        blocks: [paragraph('ok')],
      ).publishErrors,
      ['title'],
    );
    expect(
      ArticleDraft(
        id: '1',
        authorId: 'a',
        title: 'ok',
        blocks: [paragraph('x' * 100001)],
      ).publishErrors,
      ['body'],
    );
    expect(
      ArticleDraft(
        id: '1',
        authorId: 'a',
        title: 'ok',
        blocks: [paragraph('a\u202Eb')],
      ).publishErrors,
      ['body'],
    );
  });

  test('excerpt collapses whitespace and never splits surrogate pairs', () {
    final draft = ArticleDraft(
      id: '1',
      authorId: 'a',
      blocks: [paragraph('  😀\n\tword  next ')],
    );
    expect(draft.excerpt(maxCodePoints: 1), '😀');
    expect(draft.excerpt(), '😀 word next');
    expect(draft.excerpt(maxCodePoints: 0), '');
    expect(draft.wordCount, 3);
    expect(() => draft.excerpt(maxCodePoints: -1), throwsRangeError);
  });

  test('links reject script URLs, credentials and missing hosts', () {
    for (final link in [
      'javascript:alert(1)',
      'data:text/html,x',
      '/relative',
      'https://',
      'https://user:pass@example.com',
    ]) {
      expect(() => ArticleTextRun(text: 'x', link: link), throwsArgumentError);
    }
  });

  test('malformed and future payloads fail explicitly', () {
    final valid = ArticleDraft(id: '1', authorId: 'a').toJson();
    for (final value in [
      null,
      [],
      {...valid, 'schemaVersion': 2},
      {...valid, 'revision': -1},
      {...valid, 'blocks': 'bad'},
      {...valid, 'id': ''},
    ]) {
      expect(() => ArticleDraft.fromJson(value), throwsFormatException);
    }
    expect(
      () => ArticleBlock.fromJson({'kind': 'future', 'runs': []}),
      throwsFormatException,
    );
    expect(
      () => ArticleBlock.fromJson({'kind': 'image', 'runs': []}),
      throwsFormatException,
    );
    expect(
      () => ArticleBlock(
        kind: ArticleBlockKind.divider,
        runs: [ArticleTextRun(text: 'x')],
      ),
      throwsArgumentError,
    );
  });
}
