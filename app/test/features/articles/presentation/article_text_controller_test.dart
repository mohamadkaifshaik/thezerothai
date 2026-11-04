import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/presentation/article_text_controller.dart';

void main() {
  test('formatting splits only selection and survives inserted characters', () {
    final controller = ArticleTextController([
      ArticleTextRun(text: 'hello world'),
    ]);
    addTearDown(controller.dispose);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    expect(controller.format(mark: ArticleMark.bold), isTrue);
    expect(controller.runs.first.text, 'hello');
    expect(controller.runs.first.marks, {ArticleMark.bold});
    expect(controller.runs.last.marks, isEmpty);
    controller.value = const TextEditingValue(
      text: 'hello! world',
      selection: TextSelection.collapsed(offset: 6),
    );
    expect(
      controller.runs.where((run) => run.text.contains('!')).single.marks,
      {ArticleMark.bold},
    );
    expect(controller.runs.last.text, ' world');
  });
  test('deletion preserves later styles and links', () {
    final controller = ArticleTextController([
      ArticleTextRun(text: 'before '),
      ArticleTextRun(text: 'linked', link: 'https://example.com'),
      ArticleTextRun(text: ' after', marks: [ArticleMark.italic]),
    ]);
    addTearDown(controller.dispose);
    controller.text = 'linked after';
    expect(controller.runs.first.link, 'https://example.com');
    expect(controller.runs.last.marks, {ArticleMark.italic});
  });
  test('reapplying mark removes it from the complete selection', () {
    final controller = ArticleTextController([
      ArticleTextRun(text: 'a', marks: [ArticleMark.bold]),
      ArticleTextRun(text: 'b', marks: [ArticleMark.bold, ArticleMark.italic]),
    ]);
    addTearDown(controller.dispose);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    controller.format(mark: ArticleMark.bold);
    expect(
      controller.runs.every((r) => !r.marks.contains(ArticleMark.bold)),
      isTrue,
    );
    expect(controller.runs.last.marks, {ArticleMark.italic});
  });
}
