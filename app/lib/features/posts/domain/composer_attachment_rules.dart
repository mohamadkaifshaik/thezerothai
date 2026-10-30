/// Name of the polls flag as exposed through `GetMeResponse.enabled_features`
/// (ADR-0029 D12, `FEATURE_POLLS`). The Poll button needs this and
/// `engagement`. A missing name means off. Never hardcode `'polls'` elsewhere.
const kFeaturePolls = 'polls';

/// Name of the GIF flag (ADR-0029 D12, `FEATURE_GIF`). The GIF button needs
/// this and `media`. A missing name means off. Never hardcode `'gif'`
/// elsewhere.
const kFeatureGif = 'gif';

/// Why a composer toolbar button is switched off. The tooltip is the reason
/// in words (a disabled button always says why, W6-11).
enum ComposerBlock {
  /// The button is available.
  none,
  scheduled,
  hasPoll,
  hasGif,
  hasPhotos;

  /// The tooltip of a button that this block disables.
  String get pollTooltip => switch (this) {
    scheduled => "Polls can't be scheduled",
    hasGif => "Polls can't have a GIF",
    hasPhotos => "Polls can't have photos",
    _ => 'Add poll',
  };

  String get gifTooltip => switch (this) {
    hasPoll => "Polls can't have a GIF",
    hasPhotos => "A GIF can't be added to photos",
    _ => 'Add a GIF',
  };

  String get photoTooltip => switch (this) {
    hasPoll => "Polls can't have photos",
    hasGif => "A GIF can't be added to photos",
    _ => 'Add photos',
  };

  String get scheduleTooltip => switch (this) {
    hasPoll => "Polls can't be scheduled",
    _ => 'Schedule post',
  };
}

/// What the composer's bottom bar offers, in X's order (photo, GIF, poll,
/// schedule): one place decides it (ADR-0029 F4/F5, W6-11); widgets read the
/// answer and never restate a rule.
///
/// Inputs are facts about the draft: [hasPhotos], [hasGif] and [hasPoll] say
/// what is attached now, [scheduled] whether a time is set. [flagPolls] /
/// [flagGif] are the raw flags; the `engagement` and `media` prerequisites are
/// folded in by the caller as [engagementOn] / [mediaOn]. A reply or quote
/// composer never offers a poll ([isReply] / [isQuote]; a reply has no
/// composer screen today, the rule is here so the answer is never wrong).
class ComposerAttachmentRules {
  const ComposerAttachmentRules({
    required this.flagPolls,
    required this.engagementOn,
    required this.flagGif,
    required this.mediaOn,
    this.isReply = false,
    this.isQuote = false,
    this.hasPhotos = false,
    this.hasGif = false,
    this.hasPoll = false,
    this.scheduled = false,
  });

  final bool flagPolls;
  final bool engagementOn;
  final bool flagGif;
  final bool mediaOn;
  final bool isReply;
  final bool isQuote;
  final bool hasPhotos;
  final bool hasGif;
  final bool hasPoll;
  final bool scheduled;

  /// The Poll button exists at all.
  bool get showPoll => flagPolls && engagementOn && !isReply && !isQuote;

  /// The GIF button exists at all.
  bool get showGif => flagGif && mediaOn;

  /// A poll disables photos, GIF and Schedule; a schedule disables the poll;
  /// a GIF disables photos and the poll; photos disable the GIF and the poll.
  ComposerBlock get poll {
    if (scheduled) return ComposerBlock.scheduled;
    if (hasGif) return ComposerBlock.hasGif;
    if (hasPhotos) return ComposerBlock.hasPhotos;
    return ComposerBlock.none;
  }

  ComposerBlock get gif {
    if (hasPoll) return ComposerBlock.hasPoll;
    if (hasPhotos) return ComposerBlock.hasPhotos;
    return ComposerBlock.none;
  }

  ComposerBlock get photo {
    if (hasPoll) return ComposerBlock.hasPoll;
    if (hasGif) return ComposerBlock.hasGif;
    return ComposerBlock.none;
  }

  ComposerBlock get schedule =>
      hasPoll ? ComposerBlock.hasPoll : ComposerBlock.none;
}
