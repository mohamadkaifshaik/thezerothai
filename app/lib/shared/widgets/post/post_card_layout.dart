part of 'post_card.dart';

/// Opens [uri] in the external browser (a new tab on web). Only ever called
/// with an `http(s)` URL produced by [parsePostText]. Returns false when the
/// platform could not open it (never throws).
Future<bool> launchPostLink(Uri uri) async {
  try {
    return await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
  } catch (_) {
    return false;
  }
}

/// Lines of post text a list card shows before "Show more" (the post
/// detail view shows all of it).
const kPostTextClampLines = 6;

/// The same for a post with media (images or a GIF): two lines, with
/// "... Show more" inline at the end of the second.
const kPostMediaTextClampLines = 2;

/// The card's side gutter for a window [windowWidth] wide: 20 dp on phones
/// (the mobile `.post`, `padding: 14px 20px`), 16 dp from the tablet width
/// up (dz.css `.post`, `14px 16px`). Rows drawn in line with the cards (the
/// skeleton, the composer entry, the thread rail) use it too.
double postCardGutter(double windowWidth) =>
    windowWidth < AppBreakpoints.mobile ? kPostGutterPhone : AppSpacing.md;

/// [postCardGutter] on phones.
const kPostGutterPhone = AppSpacing.md + AppSpacing.xs;

/// [postCardGutter] for the window of [context].
double postCardGutterOf(BuildContext context) =>
    postCardGutter(MediaQuery.sizeOf(context).width);

/// Space inside the 48 dp avatar tap box on each side of the 42 dp circle.
const kPostAvatarInset = (AppSpacing.minTapTarget - AppSize.avatarPost) / 2;

/// The list card's top padding: the avatar circle starts 14 dp down, as in
/// the designs (`.post` 14 dp), inside its 48 dp tap box.
const kPostListTop = 14 - kPostAvatarInset;

/// Between the avatar column and the body (`.post` `gap: 12px`).
const kPostAvatarGap = AppSpacing.smd;

/// Where the body column starts, from the card's start gutter.
const kPostBodyStart = AppSpacing.minTapTarget + kPostAvatarGap;
