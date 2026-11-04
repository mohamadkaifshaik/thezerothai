import 'package:flutter/material.dart';

import '../domain/article.dart';

/// Text editing retains marks on unchanged ranges rather than flattening the
/// article when a character is inserted or removed.
class ArticleTextController extends TextEditingController {
  ArticleTextController(List<ArticleTextRun> runs)
    : _runs = List.of(runs),
      super(text: runs.map((r) => r.text).join()) {
    addListener(_edited);
  }
  List<ArticleTextRun> _runs;
  List<ArticleTextRun> get runs => List.unmodifiable(_runs);
  String get _runText => _runs.map((r) => r.text).join();
  void _edited() {
    final before = _runText;
    if (before == text) return;
    var start = 0;
    while (start < before.length &&
        start < text.length &&
        before[start] == text[start]) {
      start++;
    }
    var oldEnd = before.length;
    var newEnd = text.length;
    while (oldEnd > start &&
        newEnd > start &&
        before[oldEnd - 1] == text[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    final inherited = _at(start > 0 ? start - 1 : start);
    _runs = [
      ..._slice(0, start),
      if (newEnd > start)
        ArticleTextRun(
          text: text.substring(start, newEnd),
          marks: inherited?.marks ?? const [],
          link: inherited?.link,
        ),
      ..._slice(oldEnd, before.length),
    ];
  }

  ArticleTextRun? _at(int offset) {
    var cursor = 0;
    for (final run in _runs) {
      cursor += run.text.length;
      if (offset < cursor) return run;
    }
    return null;
  }

  List<ArticleTextRun> _slice(int start, int end) {
    final result = <ArticleTextRun>[];
    var cursor = 0;
    for (final run in _runs) {
      final a = (start - cursor).clamp(0, run.text.length);
      final b = (end - cursor).clamp(0, run.text.length);
      if (a < b) {
        result.add(
          ArticleTextRun(
            text: run.text.substring(a, b),
            marks: run.marks,
            link: run.link,
          ),
        );
      }
      cursor += run.text.length;
    }
    return result;
  }

  bool format({ArticleMark? mark, String? link}) {
    if (!selection.isValid || selection.isCollapsed) return false;
    final start = selection.start;
    final end = selection.end;
    final middle = _slice(start, end);
    final remove =
        mark != null && middle.every((run) => run.marks.contains(mark));
    _runs = [
      ..._slice(0, start),
      ...middle.map(
        (run) => ArticleTextRun(
          text: run.text,
          marks: mark == null
              ? run.marks
              : (Set<ArticleMark>.of(run.marks)
                  ..remove(mark)
                  ..addAll(remove ? [] : [mark])),
          link: link ?? run.link,
        ),
      ),
      ..._slice(end, text.length),
    ];
    notifyListeners();
    return true;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => TextSpan(
    style: style,
    children: _runs
        .map((run) => TextSpan(text: run.text, style: articleRunStyle(run)))
        .toList(),
  );
}

TextStyle articleRunStyle(ArticleTextRun run) => TextStyle(
  fontWeight: run.marks.contains(ArticleMark.bold) ? FontWeight.bold : null,
  fontStyle: run.marks.contains(ArticleMark.italic) ? FontStyle.italic : null,
  fontFamily: run.marks.contains(ArticleMark.code) ? 'monospace' : null,
  decoration: TextDecoration.combine([
    if (run.marks.contains(ArticleMark.strikethrough))
      TextDecoration.lineThrough,
    if (run.marks.contains(ArticleMark.underline) || run.link != null)
      TextDecoration.underline,
  ]),
);
