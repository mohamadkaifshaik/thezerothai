import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../../shared/format/single_line_text.dart';
import 'lists_feature_flag.dart';

/// Why a List name or description is refused before sending (W5-49). The
/// server (`lists.validateName` / `validateDescription`, ADR-0030 D2) runs the
/// same rules through `identity.SingleLineText`, so the two agree on
/// `testdata/profile_text/single_line_text.json`; the server stays
/// authoritative.
enum ListTextIssue {
  /// Name only: empty after trim.
  empty,

  /// More code points than the limit, after trim and NFC.
  tooLong,

  /// Control, line break, bidi control (one line of plain text only).
  forbiddenCharacter,

  /// Invisible format character, filler, or no visible character.
  invisibleCharacter,
}

/// Trimmed, then NFC: the server's order, so the count the user sees is the
/// count the server checks.
String normalizeListText(String raw) => unorm.nfc(raw.trim());

ListTextIssue? _check(String raw, {required int min, required int max}) {
  final text = normalizeListText(raw);
  final length = text.runes.length;
  if (length < min) return ListTextIssue.empty;
  if (length > max) return ListTextIssue.tooLong;
  return switch (singleLineIssue(text)) {
    SingleLineIssue.forbidden => ListTextIssue.forbiddenCharacter,
    SingleLineIssue.invisible => ListTextIssue.invisibleCharacter,
    null => null,
  };
}

/// Why [raw] cannot be a List name (1 to [kListNameMaxLength] code points), or
/// null.
ListTextIssue? listNameIssue(String raw) =>
    _check(raw, min: 1, max: kListNameMaxLength);

/// Why [raw] cannot be a List description (0 to [kListDescriptionMaxLength]
/// code points; empty is valid), or null.
ListTextIssue? listDescriptionIssue(String raw) =>
    _check(raw, min: 0, max: kListDescriptionMaxLength);

/// Inline error under the name field, or null. The wording follows the server's
/// ("a visible character, one line").
String? listNameFieldError(ListTextIssue? issue) => switch (issue) {
  null || ListTextIssue.empty => null,
  ListTextIssue.tooLong => 'At most $kListNameMaxLength characters.',
  ListTextIssue.forbiddenCharacter => 'Use one line of plain text.',
  ListTextIssue.invisibleCharacter =>
    'The name must contain a visible character and no invisible ones.',
};

/// Inline error under the description field, or null.
String? listDescriptionFieldError(ListTextIssue? issue) => switch (issue) {
  null || ListTextIssue.empty => null,
  ListTextIssue.tooLong => 'At most $kListDescriptionMaxLength characters.',
  ListTextIssue.forbiddenCharacter => 'Use one line of plain text.',
  ListTextIssue.invisibleCharacter =>
    'Use one line of plain text, with no invisible characters.',
};
