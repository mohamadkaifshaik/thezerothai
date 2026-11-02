import '../../../shared/format/single_line_text.dart';
import '../../lists/domain/list_text_rules.dart' show normalizeListText;
import 'communities_feature_flag.dart';

/// Why a community field is refused before sending (W5-31). The server
/// (ADR-0031 D2) checks the same limits after trim and NFC and stays
/// authoritative; this only saves a wasted call.
enum CommunityTextIssue {
  /// Empty after trim (name and rule title only).
  empty,

  /// More code points than the limit, after trim and NFC.
  tooLong,

  /// Control, line break, bidi control, invisible characters (one line).
  notPlainOneLine,

  /// Description and rule text (several lines allowed): a control other than
  /// LF, a line separator, a bidi control, an invisible format character or a
  /// filler (W5-55b).
  notPlainText,
}

/// Code points as the server counts them (trim, then NFC).
int communityTextLength(String raw) => normalizeListText(raw).runes.length;

CommunityTextIssue? _oneLine(String raw, {required int max}) {
  final text = normalizeListText(raw);
  if (text.isEmpty) return CommunityTextIssue.empty;
  if (text.runes.length > max) return CommunityTextIssue.tooLong;
  return singleLineIssue(text) == null
      ? null
      : CommunityTextIssue.notPlainOneLine;
}

/// Several lines allowed (`identity.BioText`): length, then the shared scan
/// (W5-55b).
CommunityTextIssue? _multiLine(String raw, {required int max}) {
  final text = normalizeListText(raw);
  if (text.runes.length > max) return CommunityTextIssue.tooLong;
  return multiLineTextIssue(text) == null
      ? null
      : CommunityTextIssue.notPlainText;
}

/// 1 to [kCommunityNameMaxLength] code points, one line.
CommunityTextIssue? communityNameIssue(String raw) =>
    _oneLine(raw, max: kCommunityNameMaxLength);

/// 0 to [kCommunityDescriptionMaxLength] code points.
CommunityTextIssue? communityDescriptionIssue(String raw) =>
    _multiLine(raw, max: kCommunityDescriptionMaxLength);

/// 1 to [kCommunityRuleTitleMaxLength] code points, one line.
CommunityTextIssue? communityRuleTitleIssue(String raw) =>
    _oneLine(raw, max: kCommunityRuleTitleMaxLength);

/// 0 to [kCommunityRuleTextMaxLength] code points.
CommunityTextIssue? communityRuleTextIssue(String raw) =>
    _multiLine(raw, max: kCommunityRuleTextMaxLength);

/// Inline error for a field, or null (an empty required field shows none: the
/// Create button stays disabled instead).
String? communityFieldError(CommunityTextIssue? issue, {required int max}) =>
    switch (issue) {
      null || CommunityTextIssue.empty => null,
      CommunityTextIssue.tooLong => 'At most $max characters.',
      CommunityTextIssue.notPlainOneLine => 'Use one line of plain text.',
      CommunityTextIssue.notPlainText =>
        'Use plain text, with no invisible characters.',
    };
