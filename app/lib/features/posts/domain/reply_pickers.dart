import 'reply_start.dart';

/// Which pickers a reply may offer: the one rule the photo viewer's reply bar
/// and the reply composer share.
///
/// Photo needs the `media` flag and the posts `media` sub-feature (not known
/// to be off). GIF needs photo's conditions plus the `gif` flag and the
/// `gif` sub-feature. [mediaFlag] / [gifFlag] are the server flags for the
/// caller; [mediaSub] / [gifSub] say the posts gate has not seen a
/// FEATURE_DISABLED for them (`PostsRepository.subFeatureEnabled`).
class ReplyPickers {
  const ReplyPickers({
    required bool mediaFlag,
    required bool gifFlag,
    required bool mediaSub,
    required bool gifSub,
  }) : photo = mediaFlag && mediaSub,
       gif = mediaFlag && mediaSub && gifFlag && gifSub;

  final bool photo;
  final bool gif;

  /// [start] as the composer may honour it: a picker start that is not
  /// offered becomes plain [ReplyStart.text].
  ReplyStart effective(ReplyStart start) => switch (start) {
    ReplyStart.photo => photo ? ReplyStart.photo : ReplyStart.text,
    ReplyStart.gif => gif ? ReplyStart.gif : ReplyStart.text,
    _ => start,
  };
}
