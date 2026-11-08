import 'dart:convert';

/// Structured article content. Limits and JSON format are project choices,
/// independent of X's server contract. Drafts may be incomplete while editing.
const articleSchemaVersion = 1;
const articleMaxTitleCodePoints = 100;
const articleMaxBodyCodePoints = 100000;
const articleMaxBlocks = 1000;

/// The server's cap on the serialized body: UTF-8 bytes of the JSON block
/// array sent as `body_json` (backend articles maxBodyBytes). It counts
/// formatting, links and JSON syntax, not only text, so it can bind well
/// before [articleMaxBodyCodePoints] (CJK is 3 bytes, emoji 4).
const articleMaxBodyBytes = 180000;

enum ArticleMark { bold, italic, underline, strikethrough, code }

enum ArticleBlockKind {
  paragraph,
  heading1,
  heading2,
  quote,
  bulletedListItem,
  numberedListItem,
  code,
  image,
  divider,
}

class ArticleTextRun {
  ArticleTextRun({
    required this.text,
    Iterable<ArticleMark> marks = const [],
    this.link,
  }) : marks = Set.unmodifiable(marks) {
    if (link != null && !articleLinkAllowed(link!)) {
      throw ArgumentError.value(link, 'link', 'Expected an HTTP(S) URL');
    }
  }

  final String text;
  final Set<ArticleMark> marks;
  final String? link;

  Map<String, Object?> toJson() => {
    'text': text,
    'marks': marks.map((mark) => mark.name).toList()..sort(),
    if (link != null) 'link': link,
  };

  factory ArticleTextRun.fromJson(Object? value) {
    final json = _map(value);
    final rawMarks = json['marks'];
    if (rawMarks is! List) throw const FormatException('Invalid marks');
    final link = _optionalString(json, 'link');
    if (link != null && !articleLinkAllowed(link)) {
      throw const FormatException('Invalid article link');
    }
    return ArticleTextRun(
      text: _string(json, 'text'),
      marks: rawMarks.map((value) => _enum(ArticleMark.values, value)),
      link: link,
    );
  }
}

bool articleLinkAllowed(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

class ArticleBlock {
  ArticleBlock({
    required this.kind,
    Iterable<ArticleTextRun> runs = const [],
    this.mediaId,
    this.altText = '',
  }) : runs = List.unmodifiable(runs) {
    if (kind == ArticleBlockKind.image) {
      if (mediaId == null || mediaId!.trim().isEmpty || this.runs.isNotEmpty) {
        throw ArgumentError('Images require a media id and no text runs');
      }
    } else if (mediaId != null || altText.isNotEmpty) {
      throw ArgumentError('Media fields belong to image blocks');
    }
    if (kind == ArticleBlockKind.divider && this.runs.isNotEmpty) {
      throw ArgumentError('Dividers cannot have text runs');
    }
  }

  final ArticleBlockKind kind;
  final List<ArticleTextRun> runs;
  final String? mediaId;
  final String altText;
  String get plainText => runs.map((run) => run.text).join();

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'runs': runs.map((run) => run.toJson()).toList(),
    if (mediaId != null) 'mediaId': mediaId,
    if (kind == ArticleBlockKind.image) 'altText': altText,
  };

  factory ArticleBlock.fromJson(Object? value) {
    final json = _map(value);
    final runs = json['runs'];
    if (runs is! List) throw const FormatException('Invalid block runs');
    try {
      return ArticleBlock(
        kind: _enum(ArticleBlockKind.values, json['kind']),
        runs: runs.map(ArticleTextRun.fromJson),
        mediaId: _optionalString(json, 'mediaId'),
        altText: _optionalString(json, 'altText') ?? '',
      );
    } on ArgumentError {
      throw const FormatException('Invalid article block');
    }
  }
}

class ArticleDraft {
  ArticleDraft({
    required this.id,
    required this.authorId,
    this.revision = 0,
    this.title = '',
    this.coverMediaId,
    Iterable<ArticleBlock> blocks = const [],
  }) : blocks = List.unmodifiable(blocks) {
    if (id.trim().isEmpty || authorId.trim().isEmpty || revision < 0) {
      throw ArgumentError(
        'Draft identity and nonnegative revision are required',
      );
    }
  }

  final String id;
  final String authorId;
  final int revision;
  final String title;
  final String? coverMediaId;
  final List<ArticleBlock> blocks;

  String get plainText => blocks
      .map((block) => block.plainText)
      .where((text) => text.isNotEmpty)
      .join('\n');

  /// Whitespace-delimited count; scripts without spaces are not segmented.
  int get wordCount =>
      RegExp(r'\S+', unicode: true).allMatches(plainText).length;

  String excerpt({int maxCodePoints = 160}) {
    if (maxCodePoints < 0) throw RangeError.value(maxCodePoints);
    return String.fromCharCodes(
      plainText
          .replaceAll(RegExp(r'\s+', unicode: true), ' ')
          .trim()
          .runes
          .take(maxCodePoints),
    );
  }

  /// The exact `body_json` a save sends.
  String get bodyJson => jsonEncode(blocks.map((b) => b.toJson()).toList());

  /// UTF-8 size of [bodyJson], the quantity the server caps.
  int get bodyBytes => utf8.encode(bodyJson).length;

  /// Limits the server enforces on every save, publishing or not: 'bodySize'
  /// ([articleMaxBodyBytes]) and 'bodyLength' ([articleMaxBodyCodePoints]).
  /// A draft with save errors is kept locally and not sent.
  List<String> get saveErrors => List.unmodifiable([
    if (bodyBytes > articleMaxBodyBytes) 'bodySize',
    if (plainText.runes.length > articleMaxBodyCodePoints) 'bodyLength',
  ]);

  /// Returns stable field keys. This is client validation; the server must
  /// independently validate ownership, revisions, media and publish limits.
  List<String> get publishErrors {
    final errors = <String>[];
    if (title.trim().isEmpty ||
        title.runes.length > articleMaxTitleCodePoints ||
        title.contains('\n') ||
        title.contains('\r') ||
        _controls.hasMatch(title)) {
      errors.add('title');
    }
    if (plainText.trim().isEmpty ||
        plainText.runes.length > articleMaxBodyCodePoints ||
        blocks.length > articleMaxBlocks ||
        _controls.hasMatch(plainText)) {
      errors.add('body');
    }
    if (bodyBytes > articleMaxBodyBytes) {
      errors.add('bodySize');
    }
    if (coverMediaId != null && coverMediaId!.trim().isEmpty) {
      errors.add('cover');
    }
    if (blocks.any(
      (block) =>
          block.altText.runes.length > 1000 ||
          _controls.hasMatch(block.altText),
    )) {
      errors.add('altText');
    }
    return List.unmodifiable(errors);
  }

  ArticleDraft revise({
    required int expectedRevision,
    String? title,
    List<ArticleBlock>? blocks,
    String? coverMediaId,
    bool removeCover = false,
  }) {
    if (expectedRevision != revision) {
      throw StateError('Stale article revision');
    }
    if (removeCover && coverMediaId != null) {
      throw ArgumentError('Conflicting cover edit');
    }
    return ArticleDraft(
      id: id,
      authorId: authorId,
      revision: revision + 1,
      title: title ?? this.title,
      blocks: blocks ?? this.blocks,
      coverMediaId: removeCover ? null : coverMediaId ?? this.coverMediaId,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': articleSchemaVersion,
    'id': id,
    'authorId': authorId,
    'revision': revision,
    'title': title,
    if (coverMediaId != null) 'coverMediaId': coverMediaId,
    'blocks': blocks.map((block) => block.toJson()).toList(),
  };

  factory ArticleDraft.fromJson(Object? value) {
    final json = _map(value);
    if (json['schemaVersion'] != articleSchemaVersion) {
      throw const FormatException('Unsupported article schema version');
    }
    final blocks = json['blocks'];
    final revision = json['revision'];
    if (blocks is! List ||
        blocks.length > articleMaxBlocks ||
        revision is! int ||
        revision < 0) {
      throw const FormatException('Invalid draft blocks or revision');
    }
    try {
      return ArticleDraft(
        id: _string(json, 'id'),
        authorId: _string(json, 'authorId'),
        revision: revision,
        title: _string(json, 'title'),
        coverMediaId: _optionalString(json, 'coverMediaId'),
        blocks: blocks.map(ArticleBlock.fromJson),
      );
    } on ArgumentError {
      throw const FormatException('Invalid article draft');
    }
  }
}

final _controls = RegExp(
  r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u202A-\u202E\u2066-\u2069]',
);

Map<dynamic, dynamic> _map(Object? value) {
  if (value is! Map) throw const FormatException('Expected article object');
  return value;
}

String _string(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key');
  return value;
}

String? _optionalString(Map<dynamic, dynamic> json, String key) {
  if (json[key] == null) return null;
  return _string(json, key);
}

T _enum<T extends Enum>(List<T> values, Object? name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw const FormatException('Unknown article enum value');
}
