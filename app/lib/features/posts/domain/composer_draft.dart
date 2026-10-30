import 'reply_audience.dart';

/// Name of the drafts flag as exposed through `GetMeResponse.enabled_features`
/// (ADR-0029 D12, `FEATURE_DRAFTS`). Client-only: no RPC is gated by it. It
/// hides the Drafts button, "Save post?", the Unsent tab and autosave; rows
/// already on the device are kept while it is off. A missing name means off.
/// Never hardcode `'drafts'` anywhere else.
const kFeatureDrafts = 'drafts';

/// Most drafts one account keeps on a device (ADR-0029, W6-14); the 51st
/// removes the oldest.
const kMaxDrafts = 50;

/// Most code points of text a draft keeps (the composer's own limits are
/// lower; this is a storage bound, not a rule).
const kMaxDraftCodePoints = 2000;

/// The poll part of a draft, as plain Dart. It is mapped to the generated
/// `PollDraft` (choices, `duration_minutes`) when the poll builder lands, so
/// the store does not depend on generated code (ADR-0029).
class DraftPoll {
  const DraftPoll({required this.choices, required this.durationMinutes});

  /// The choice texts as typed (may include empty rows being edited).
  final List<String> choices;
  final int durationMinutes;

  Map<String, Object?> toJson() => {'c': choices, 'd': durationMinutes};

  /// Null when [json] is not a well-formed poll (a damaged row is shown
  /// without its poll rather than failing the list).
  static DraftPoll? fromJson(Object? json) {
    if (json is! Map) return null;
    final c = json['c'];
    final d = json['d'];
    if (c is! List || d is! int) return null;
    if (c.any((e) => e is! String)) return null;
    return DraftPoll(
      choices: List<String>.unmodifiable(c.cast<String>()),
      durationMinutes: d,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DraftPoll &&
      other.durationMinutes == durationMinutes &&
      _sameChoices(other.choices, choices);

  @override
  int get hashCode => Object.hash(durationMinutes, Object.hashAll(choices));
}

bool _sameChoices(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One unsent post kept on the device (ADR-0029 F7/F8): text, poll, reply
/// audience and disclosure labels. Never photos or GIFs.
class ComposerDraft {
  const ComposerDraft({
    required this.id,
    required this.uid,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.poll,
    this.replyAudience = ReplyAudience.everyone,
    this.paidPartnership = false,
    this.madeWithAi = false,
  });

  final String id;

  /// The account that wrote it; another account never reads it.
  final String uid;
  final String text;
  final DraftPoll? poll;
  final ReplyAudience replyAudience;
  final bool paidPartnership;
  final bool madeWithAi;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Nothing worth keeping: no text (after trimming) and no poll choice text.
  bool get isEmpty =>
      text.trim().isEmpty &&
      (poll == null || poll!.choices.every((c) => c.trim().isEmpty));

  ComposerDraft copyWith({
    String? text,
    DraftPoll? poll,
    bool clearPoll = false,
    ReplyAudience? replyAudience,
    bool? paidPartnership,
    bool? madeWithAi,
    DateTime? updatedAt,
  }) => ComposerDraft(
    id: id,
    uid: uid,
    text: text ?? this.text,
    poll: clearPoll ? null : (poll ?? this.poll),
    replyAudience: replyAudience ?? this.replyAudience,
    paidPartnership: paidPartnership ?? this.paidPartnership,
    madeWithAi: madeWithAi ?? this.madeWithAi,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is ComposerDraft &&
      other.id == id &&
      other.uid == uid &&
      other.text == text &&
      other.poll == poll &&
      other.replyAudience == replyAudience &&
      other.paidPartnership == paidPartnership &&
      other.madeWithAi == madeWithAi &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    uid,
    text,
    poll,
    replyAudience,
    paidPartnership,
    madeWithAi,
    createdAt,
    updatedAt,
  );
}
