/// How the reply composer opens (`/compose/reply/:id?start=<name>`), from the
/// photo viewer's "Post your reply" bar: the field focused with the keyboard
/// up ([text]), the photo picker started ([photo]), the GIF picker started
/// ([gif]), or the emoji entry ([emoji]).
///
/// [emoji] cannot force the platform's emoji keyboard from Flutter, so it only
/// focuses the field (the same as [text]); the keyboard's own emoji key is one
/// tap away.
enum ReplyStart {
  text,
  photo,
  gif,
  emoji;

  /// The query value, or null for [text] (the default: no query).
  String? get query => this == ReplyStart.text ? null : name;

  /// The start named by a route's `start` query; anything else is [text].
  static ReplyStart parse(String? value) => ReplyStart.values.firstWhere(
    (s) => s.name == value,
    orElse: () => ReplyStart.text,
  );
}
